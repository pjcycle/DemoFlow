//
//  TrimModels.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import CoreMedia
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
