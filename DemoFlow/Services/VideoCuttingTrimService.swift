//
//  VideoCuttingTrimService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import CoreMedia
import Foundation

struct VideoCuttingTrimService {
    func makeProject(sourceURL: URL, sourceDuration: CMTime, deleteRanges: [CutRange]) -> TrimProject {
        let durationSeconds = max(0, sourceDuration.seconds)
        let normalized = deleteRanges
            .map(\.normalized)
            .compactMap { range -> CutRange? in
                let start = max(0, min(range.start.seconds, durationSeconds))
                let end = max(0, min(range.end.seconds, durationSeconds))
                guard end > start else { return nil }
                return CutRange(
                    id: range.id,
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
            }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.end < rhs.end
                }
                return lhs.start < rhs.start
            }
        return TrimProject(sourceURL: sourceURL, deleteRanges: normalized)
    }

    func makeProject(sourceURL: URL, sourceDuration: CMTime, keepStart: Double, keepEnd: Double) -> TrimProject? {
        let durationSeconds = max(0, sourceDuration.seconds)
        guard durationSeconds > 0 else { return nil }

        let clampedStart = max(0, min(keepStart, durationSeconds))
        let clampedEnd = max(0, min(keepEnd, durationSeconds))
        let normalizedStart = min(clampedStart, clampedEnd)
        let normalizedEnd = max(clampedStart, clampedEnd)

        guard normalizedEnd > normalizedStart else { return nil }

        var deleteRanges: [CutRange] = []
        if normalizedStart > 0 {
            deleteRanges.append(
                CutRange(
                    start: .zero,
                    end: CMTime(seconds: normalizedStart, preferredTimescale: 600)
                )
            )
        }

        if normalizedEnd < durationSeconds {
            deleteRanges.append(
                CutRange(
                    start: CMTime(seconds: normalizedEnd, preferredTimescale: 600),
                    end: CMTime(seconds: durationSeconds, preferredTimescale: 600)
                )
            )
        }

        return makeProject(
            sourceURL: sourceURL,
            sourceDuration: sourceDuration,
            deleteRanges: deleteRanges
        )
    }
}
