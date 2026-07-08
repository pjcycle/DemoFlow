//
//  AudioTrimModels.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import CoreGraphics
import Foundation

struct AudioTrimRange: Equatable {
    var startTime: TimeInterval
    var endTime: TimeInterval

    var duration: TimeInterval {
        max(endTime - startTime, 0)
    }
}

struct AudioTrimSegment: Identifiable, Equatable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval

    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }

    var duration: TimeInterval {
        max(endTime - startTime, 0)
    }
}

enum AudioTrimExportAvailability: Equatable {
    case allowed(formatLabel: String)
    case blocked(reason: String)
}

struct AudioTrimDraft {
    var selectedPreparedAsset: AudioPreparedAsset?
    var waveformSamples: [CGFloat] = []
    var activeRange: AudioTrimRange?
    var zoomLevel: CGFloat = 1
    var playheadTime: TimeInterval = 0
    var exportFileName: String = ""
    var preferredOutputFormat: AudioTranscodeOutputFormat?
    var originalFormatHint: String = ""
}

struct AudioTrimExportResult {
    let outputURL: URL
    let duration: Double
    let byteCount: Int64
}

enum AudioTrimError: LocalizedError {
    case noSource
    case noSelection
    case invalidRange
    case tooShort
    case exportUnavailable(String)
    case exportFailed(AudioToolCommandHint)
    case outputValidationFailed

    var errorDescription: String? {
        switch self {
        case .noSource:
            return L10n.tr("audio.trim.error.no_source")
        case .noSelection:
            return L10n.tr("audio.trim.error.no_selection")
        case .invalidRange:
            return L10n.tr("audio.trim.error.invalid_range")
        case .tooShort:
            return L10n.tr("audio.trim.error.too_short")
        case let .exportUnavailable(reason):
            return reason
        case let .exportFailed(hint):
            return hint.combinedMessage
        case .outputValidationFailed:
            return L10n.tr("audio.trim.error.output_validation")
        }
    }
}
