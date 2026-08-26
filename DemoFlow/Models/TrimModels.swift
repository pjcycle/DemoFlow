//
//  TrimModels.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import CoreMedia
import CoreGraphics
import Foundation

struct CutRange: Identifiable, Equatable {
    let id: UUID
    var start: CMTime
    var end: CMTime

    init(id: UUID = UUID(), start: CMTime, end: CMTime) {
        self.id = id
        self.start = start
        self.end = end
    }

    var normalized: CutRange {
        if end < start {
            return CutRange(id: id, start: end, end: start)
        }
        return self
    }

    var durationSeconds: Double {
        max(0, normalized.end.seconds - normalized.start.seconds)
    }
}

struct TrimProject: Equatable {
    var sourceURL: URL
    var deleteRanges: [CutRange]
}

struct TrimExportRequest {
    let sourceURL: URL
    let keepRanges: [CMTimeRange]
    let outputURL: URL
}

struct VideoTimelineThumbnail: Identifiable, @unchecked Sendable {
    let seconds: Double
    let image: CGImage

    var id: Double { seconds }
}

/// One contiguous source range in the editable video timeline. A split creates
/// two clips pointing at the same source file; inserted videos create a new
/// clip. The order in `timelineClips` is the order used for preview and export.
struct VideoTimelineClip: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let sourceStartSeconds: Double
    let sourceEndSeconds: Double
    let hasAudioTrack: Bool

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        sourceStartSeconds: Double,
        sourceEndSeconds: Double,
        hasAudioTrack: Bool
    ) {
        self.id = id
        self.sourceURL = sourceURL.standardizedFileURL
        self.sourceStartSeconds = max(0, sourceStartSeconds)
        self.sourceEndSeconds = max(sourceStartSeconds, sourceEndSeconds)
        self.hasAudioTrack = hasAudioTrack
    }

    var durationSeconds: Double {
        max(0, sourceEndSeconds - sourceStartSeconds)
    }

    var displayName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    func clipped(to startSeconds: Double, _ endSeconds: Double) -> VideoTimelineClip? {
        let start = max(sourceStartSeconds, min(startSeconds, sourceEndSeconds))
        let end = max(start, min(endSeconds, sourceEndSeconds))
        guard end - start > 0.0005 else { return nil }
        return VideoTimelineClip(
            sourceURL: sourceURL,
            sourceStartSeconds: start,
            sourceEndSeconds: end,
            hasAudioTrack: hasAudioTrack
        )
    }
}
