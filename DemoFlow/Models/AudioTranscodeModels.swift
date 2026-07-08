//
//  AudioTranscodeModels.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import Foundation
import UniformTypeIdentifiers

enum AudioTranscodeOutputFormat: String, CaseIterable, Identifiable {
    case mp3
    case wav
    case m4a
    case flac

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .mp3:
            return "audio.transcode.format.mp3"
        case .wav:
            return "audio.transcode.format.wav"
        case .m4a:
            return "audio.transcode.format.m4a"
        case .flac:
            return "audio.transcode.format.flac"
        }
    }

    var displayName: String {
        switch self {
        case .mp3:
            return "MP3"
        case .wav:
            return "WAV"
        case .m4a:
            return "AAC (M4A)"
        case .flac:
            return "FLAC"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3:
            return "mp3"
        case .wav:
            return "wav"
        case .m4a:
            return "m4a"
        case .flac:
            return "flac"
        }
    }

    var supportsQualityPreset: Bool {
        switch self {
        case .mp3, .m4a:
            return true
        case .wav, .flac:
            return false
        }
    }

    var suggestedContentType: UTType? {
        switch self {
        case .mp3:
            return .mp3
        case .wav:
            return .wav
        case .m4a:
            return .mpeg4Audio
        case .flac:
            return UTType(filenameExtension: "flac")
        }
    }
}

enum AudioTranscodeQualityPreset: String, CaseIterable, Identifiable {
    case small
    case balanced
    case highQuality

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .small:
            return "audio.transcode.quality.small"
        case .balanced:
            return "audio.transcode.quality.balanced"
        case .highQuality:
            return "audio.transcode.quality.high_quality"
        }
    }

    var bitrateKbps: Int {
        switch self {
        case .small:
            return 128
        case .balanced:
            return 192
        case .highQuality:
            return 256
        }
    }

    var bitrateArgument: String {
        "\(bitrateKbps)k"
    }
}

enum AudioTranscodeJobStatus: Equatable {
    case queued
    case converting
    case succeeded
    case failed

    var titleKey: String {
        switch self {
        case .queued:
            return "audio.transcode.status.queued"
        case .converting:
            return "audio.transcode.status.converting"
        case .succeeded:
            return "audio.transcode.status.succeeded"
        case .failed:
            return "audio.transcode.status.failed"
        }
    }
}

struct AudioTranscodeDraft {
    var outputFormat: AudioTranscodeOutputFormat = .m4a
    var qualityPreset: AudioTranscodeQualityPreset = .balanced
    var selectedJobID: UUID?
}

struct AudioTranscodeResult {
    let outputURL: URL
    let outputFormat: AudioTranscodeOutputFormat
    let byteCount: Int64
    let duration: Double

    var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct AudioTranscodeJob: Identifiable {
    let id: UUID
    let preparedAsset: AudioPreparedAsset
    var status: AudioTranscodeJobStatus
    var result: AudioTranscodeResult?
    var errorMessage: String?

    init(preparedAsset: AudioPreparedAsset) {
        self.id = UUID()
        self.preparedAsset = preparedAsset
        self.status = .queued
        self.result = nil
        self.errorMessage = nil
    }
}

enum AudioTranscodeError: LocalizedError {
    case missingInput
    case missingOutput
    case dependenciesUnavailable(AudioToolCommandHint)
    case conversionFailed(AudioToolCommandHint)
    case outputValidationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingInput:
            return L10n.tr("audio.transcode.error.missing_input")
        case .missingOutput:
            return L10n.tr("audio.transcode.error.missing_output")
        case let .dependenciesUnavailable(hint):
            return hint.combinedMessage
        case let .conversionFailed(hint):
            return hint.combinedMessage
        case .outputValidationFailed:
            return L10n.tr("audio.transcode.error.output_validation")
        case .cancelled:
            return L10n.tr("audio.transcode.status.cancelled")
        }
    }
}
