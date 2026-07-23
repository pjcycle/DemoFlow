import AVFoundation
import CoreMedia
import Foundation

enum SubDubTab: String, CaseIterable, Identifiable {
    case videoDubbing
    case aiVoiceover
    case subtitleSync

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .videoDubbing: return "subdub.tab.video_dubbing"
        case .aiVoiceover: return "subdub.tab.ai_voiceover"
        case .subtitleSync: return "subdub.tab.subtitle_sync"
        }
    }

    var iconName: String {
        switch self {
        case .videoDubbing: return "mic.and.signal.meter"
        case .aiVoiceover: return "sparkles.waveform"
        case .subtitleSync: return "captions.bubble"
        }
    }
}

enum SubDubSessionState: Equatable {
    case idle
    case preparing
    case ready
    case recording
    case paused
    case finished
    case exporting
    case succeeded
    case failed

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .exporting:
            return true
        default:
            return false
        }
    }
}

struct VideoDubbingRange: Equatable {
    let startTime: Double
    let endTime: Double

    var duration: Double {
        max(0, endTime - startTime)
    }

    var isValid: Bool {
        startTime.isFinite && endTime.isFinite && startTime >= 0 && duration >= 0.1
    }
}

struct VideoDubbingSegment: Equatable, Identifiable {
    let id: UUID
    let timelineStart: Double
    let timelineEnd: Double
    let audioURL: URL
    let audioStartTime: Double

    var duration: Double {
        max(0, timelineEnd - timelineStart)
    }

    init(
        id: UUID = UUID(),
        timelineStart: Double,
        timelineEnd: Double,
        audioURL: URL,
        audioStartTime: Double = 0
    ) {
        self.id = id
        self.timelineStart = timelineStart
        self.timelineEnd = timelineEnd
        self.audioURL = audioURL
        self.audioStartTime = max(0, audioStartTime)
    }
}

struct SubtitleCue: Equatable, Identifiable {
    let id: UUID
    let start: CMTime
    let end: CMTime
    let text: String

    init(id: UUID = UUID(), start: CMTime, end: CMTime, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

struct SubDubTTSRequest {
    let text: String
    let voice: String
    let speed: Double
}

protocol SubDubTTSService {
    func synthesize(request: SubDubTTSRequest) async throws -> URL
}

protocol SubtitleParser {
    func parse(url: URL) throws -> [SubtitleCue]
}

enum SubDubError: LocalizedError {
    case inputMissing
    case unsupportedVideo
    case unsupportedSubtitle
    case unsupportedAudio
    case inputUnavailable
    case outputUnavailable
    case microphonePermissionDenied
    case microphoneUnavailable
    case recordingFailed(String)
    case audioValidationFailed
    case videoValidationFailed
    case subtitleValidationFailed(String)
    case emptyText
    case apiKeyMissing
    case networkFailed(String)
    case serviceFailed(String)
    case dependencyMissing

    var errorDescription: String? {
        let reason: String
        switch self {
        case .inputMissing:
            reason = L10n.tr("subdub.error.input_missing")
        case .unsupportedVideo:
            reason = L10n.tr("subdub.error.unsupported_video")
        case .unsupportedSubtitle:
            reason = L10n.tr("subdub.error.unsupported_subtitle")
        case .unsupportedAudio:
            reason = L10n.tr("subdub.error.unsupported_audio")
        case .inputUnavailable:
            reason = L10n.tr("subdub.error.input_unavailable")
        case .outputUnavailable:
            reason = L10n.tr("subdub.error.output_unavailable")
        case .microphonePermissionDenied:
            reason = L10n.tr("subdub.error.microphone_permission")
        case .microphoneUnavailable:
            reason = L10n.tr("subdub.error.microphone_unavailable")
        case let .recordingFailed(message):
            reason = L10n.f("subdub.error.recording_failed", message)
        case .audioValidationFailed:
            reason = L10n.tr("subdub.error.audio_validation")
        case .videoValidationFailed:
            reason = L10n.tr("subdub.error.video_validation")
        case let .subtitleValidationFailed(message):
            reason = L10n.f("subdub.error.subtitle_validation", message)
        case .emptyText:
            reason = L10n.tr("subdub.error.empty_text")
        case .apiKeyMissing:
            reason = L10n.tr("subdub.error.api_key_missing")
        case let .networkFailed(message):
            reason = L10n.f("subdub.error.network_failed", message)
        case let .serviceFailed(message):
            reason = L10n.f("subdub.error.service_failed", message)
        case .dependencyMissing:
            reason = L10n.tr("subdub.error.dependency_missing")
        }
        return L10n.f(
            "subdub.error.template",
            reason,
            L10n.tr("subdub.error.next_step")
        )
    }
}

enum SubDubFileKind {
    case video
    case audio
    case subtitle
}
