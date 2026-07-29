import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation

enum SubDubTab: String, CaseIterable, Identifiable {
    case videoDubbing
    case subtitleBurning
    case audioReplacement

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .videoDubbing: return "subdub.tab.video_dubbing"
        case .subtitleBurning: return "subdub.tab.subtitle_burning"
        case .audioReplacement: return "subdub.tab.audio_replacement"
        }
    }

    var iconName: String {
        switch self {
        case .videoDubbing: return "mic.and.signal.meter"
        case .subtitleBurning: return "captions.bubble"
        case .audioReplacement: return "waveform.badge.plus"
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

enum SubtitleBurnState: Equatable {
    case idle
    case preparing
    case ready
    case extractingAudio
    case transcribing
    case exporting
    case succeeded
    case failed

    var isBusy: Bool {
        switch self {
        case .preparing, .extractingAudio, .transcribing, .exporting:
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

enum SubtitleStylePreset: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case standard
    case outline
    case movie

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .standard: return "subdub.subtitle_style.standard"
        case .outline: return "subdub.subtitle_style.outline"
        case .movie: return "subdub.subtitle_style.movie"
        }
    }

    var fontName: String { "Hiragino Sans GB" }

    var fontScale: CGFloat {
        switch self {
        case .standard, .outline: return 0.06
        case .movie: return 0.075
        }
    }

    var marginScale: CGFloat {
        switch self {
        case .standard, .outline: return 0.055
        case .movie: return 0.06
        }
    }

    var usesBackground: Bool {
        // Keep preview and the burned result free of a subtitle box.
        return false
    }

    var backgroundOpacity: Double {
        0
    }

    var isBold: Bool { self == .movie }

    var assBorderStyle: Int { 1 }

    var assOutlineWidth: Int { self == .outline ? 3 : 0 }

    func previewFontSize(forVideoHeight height: CGFloat) -> CGFloat {
        max(12, height * fontScale)
    }

    func assFontSize(forVideoHeight height: CGFloat) -> Int {
        max(12, Int((height * fontScale).rounded()))
    }

    func assMarginV(forVideoHeight height: CGFloat) -> Int {
        max(18, Int((height * marginScale).rounded()))
    }
}

struct SubtitleTimelineDocument: Codable, Equatable {
    let schemaVersion: Int
    let sourceDuration: Double
    var style: SubtitleStylePreset
    var cues: [SubtitleTimelineCue]

    init(
        schemaVersion: Int = 2,
        sourceDuration: Double,
        style: SubtitleStylePreset = .standard,
        cues: [SubtitleTimelineCue] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sourceDuration = sourceDuration
        self.style = style
        self.cues = cues
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceDuration
        case style
        case cues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sourceDuration = try container.decode(Double.self, forKey: .sourceDuration)
        style = try container.decodeIfPresent(SubtitleStylePreset.self, forKey: .style) ?? .standard
        cues = try container.decode([SubtitleTimelineCue].self, forKey: .cues)
    }
}

struct SubtitleTimelineCue: Codable, Equatable, Identifiable {
    let id: UUID
    var startTime: Double
    var endTime: Double
    var text: String

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    init(cue: SubtitleCue) {
        self.init(
            id: cue.id,
            startTime: cue.start.seconds,
            endTime: cue.end.seconds,
            text: cue.text
        )
    }

    var duration: Double { max(0, endTime - startTime) }

    var subtitleCue: SubtitleCue {
        SubtitleCue(
            id: id,
            start: CMTime(seconds: startTime, preferredTimescale: 1_000),
            end: CMTime(seconds: endTime, preferredTimescale: 1_000),
            text: text
        )
    }
}

enum AudioReplacementLanguageMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case chinese
    case english

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .automatic: return "subdub.audio_replacement.language.automatic"
        case .chinese: return "subdub.audio_replacement.language.chinese"
        case .english: return "subdub.audio_replacement.language.english"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .automatic: return nil
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        }
    }
}

enum AudioPreviewMode: String, CaseIterable, Identifiable {
    case original
    case replacement
    case imported

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .original: return "subdub.audio_replacement.preview.original"
        case .replacement: return "subdub.audio_replacement.preview.replacement"
        case .imported: return "subdub.audio_replacement.preview.imported"
        }
    }
}

enum AudioReplacementState: Equatable {
    case idle
    case generating
    case mixing
    case ready
    case exporting
    case failed

    var isBusy: Bool {
        switch self {
        case .generating, .mixing, .exporting: return true
        default: return false
        }
    }
}

enum AudioReplacementCueStatus: String, Codable, Equatable {
    case pending
    case generating
    case generated
    case failed
}

struct AudioReplacementSegment {
    let id: UUID
    let audioURL: URL
    let startTime: Double
    let endTime: Double
}

struct AudioReplacementVoiceOption: Identifiable, Equatable {
    let id: String
    let title: String
}

struct AudioReplacementDraft: Equatable {
    var cueAudioURLs: [UUID: URL] = [:]
    var cueSignatures: [UUID: String] = [:]
    var cueStatuses: [UUID: AudioReplacementCueStatus] = [:]
    var voiceIdentifier: String?
    var languageMode: AudioReplacementLanguageMode = .automatic
    var rate: Double = 1.0
    var replacementAudioURL: URL?
}

struct AudioReplacementManifest: Codable, Equatable {
    struct Cue: Codable, Equatable {
        let id: UUID
        let status: AudioReplacementCueStatus
        let signature: String
        let audioFileName: String?
    }

    let schemaVersion: Int
    var languageMode: AudioReplacementLanguageMode
    var voiceIdentifier: String?
    var rate: Double
    var replacementAudioFileName: String?
    var cues: [Cue]

    init(
        languageMode: AudioReplacementLanguageMode,
        voiceIdentifier: String?,
        rate: Double,
        replacementAudioFileName: String?,
        cues: [Cue]
    ) {
        schemaVersion = 1
        self.languageMode = languageMode
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.replacementAudioFileName = replacementAudioFileName
        self.cues = cues
    }
}

protocol AppleTTSService {
    func synthesize(
        text: String,
        voiceIdentifier: String?,
        rate: Double,
        outputURL: URL
    ) async throws -> URL
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
    case whisperDependencyMissing
    case whisperModelMissing
    case transcriptionOutputMissing
    case transcriptionInvalidJSON
    case transcriptionEmpty
    case transcriptionFailed(String)
    case subtitleBurnValidationFailed(String)
    case speechVoiceMissing
    case speechOutputMissing
    case audioReplacementTiming(String)
    case audioReplacementMixFailed(String)
    case audioReplacementValidationFailed(String)
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
        case .whisperDependencyMissing:
            reason = L10n.tr("subdub.error.whisper_dependency_missing")
        case .whisperModelMissing:
            reason = L10n.tr("subdub.error.whisper_model_missing")
        case .transcriptionOutputMissing:
            reason = L10n.tr("subdub.error.transcription_output_missing")
        case .transcriptionInvalidJSON:
            reason = L10n.tr("subdub.error.transcription_invalid_json")
        case .transcriptionEmpty:
            reason = L10n.tr("subdub.error.transcription_empty")
        case let .transcriptionFailed(message):
            reason = L10n.f("subdub.error.transcription_failed", message)
        case let .subtitleBurnValidationFailed(message):
            reason = L10n.f("subdub.error.subtitle_burn_validation", message)
        case .speechVoiceMissing:
            reason = L10n.tr("subdub.error.speech_voice_missing")
        case .speechOutputMissing:
            reason = L10n.tr("subdub.error.speech_output_missing")
        case let .audioReplacementTiming(message):
            reason = L10n.f("subdub.error.audio_replacement_timing", message)
        case let .audioReplacementMixFailed(message):
            reason = L10n.f("subdub.error.audio_replacement_mix_failed", message)
        case let .audioReplacementValidationFailed(message):
            reason = L10n.f("subdub.error.audio_replacement_validation_failed", message)
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
