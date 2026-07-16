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
