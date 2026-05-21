//
//  AudioExtractModels.swift
//  DemoFlow
//
//  Created by Codex on 2026/5/12.
//

import Foundation
import UniformTypeIdentifiers

enum AudioExtractSourceType: String, CaseIterable, Identifiable {
    case localFile
    case onlineURL

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .localFile:
            return "audio.extract.source.local"
        case .onlineURL:
            return "audio.extract.source.url"
        }
    }
}

enum AudioExtractQualityPreset: String, CaseIterable, Identifiable {
    case best
    case high
    case medium
    case low

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .best:
            return "audio.extract.quality.best"
        case .high:
            return "audio.extract.quality.high"
        case .medium:
            return "audio.extract.quality.medium"
        case .low:
            return "audio.extract.quality.low"
        }
    }

    var ffmpegQualityValue: String {
        switch self {
        case .best:
            return "0"
        case .high:
            return "2"
        case .medium:
            return "5"
        case .low:
            return "7"
        }
    }

    var ytDlpQualityValue: String {
        ffmpegQualityValue
    }
}

struct AudioExtractToolchain {
    let ffmpegURL: URL
    let ffprobeURL: URL
    let ytDlpCommand: YtDlpLaunchCommand?
}

struct YtDlpLaunchCommand {
    let executableURL: URL
    let workingDirectoryURL: URL?
    var environment: [String: String]? = nil
    let prependArguments: [String]
    let candidatePath: String

    func makeArguments(_ tail: [String]) -> [String] {
        prependArguments + tail
    }

    var rendered: String {
        ([executableURL.path] + prependArguments).joined(separator: " ")
    }
}

struct AudioExtractCommandHint {
    let reason: String
    let nextCommand: String

    var combinedMessage: String {
        "\(L10n.tr("audio.extract.error.reason")) \(reason)\n\(L10n.tr("audio.extract.error.next")) \(nextCommand)"
    }
}

struct AudioExtractResult {
    let outputDirectory: URL
    let mp3URL: URL
    let duration: Double
}

enum AudioExtractServiceError: LocalizedError {
    case missingInput
    case invalidURL
    case unsupportedLocalFile
    case missingOutputDirectory
    case outputValidationFailed
    case dependenciesUnavailable(AudioExtractCommandHint)
    case localExtractionFailed(AudioExtractCommandHint)
    case urlExtractionFailed(AudioExtractCommandHint)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingInput:
            return L10n.tr("audio.extract.error.missing_input")
        case .invalidURL:
            return L10n.tr("audio.extract.error.invalid_url")
        case .unsupportedLocalFile:
            return L10n.tr("audio.extract.error.unsupported_local")
        case .missingOutputDirectory:
            return L10n.tr("audio.extract.error.missing_output")
        case .outputValidationFailed:
            return L10n.tr("audio.extract.error.output_validation")
        case let .dependenciesUnavailable(hint):
            return hint.combinedMessage
        case let .localExtractionFailed(hint):
            return hint.combinedMessage
        case let .urlExtractionFailed(hint):
            return hint.combinedMessage
        case .cancelled:
            return L10n.tr("audio.extract.status.cancelled")
        }
    }
}

extension AudioExtractSourceType {
    var acceptsFileInput: Bool {
        self == .localFile
    }
}

extension AudioExtractServiceError {
    static func dependencyHint(_ reason: String, _ next: String) -> Self {
        .dependenciesUnavailable(AudioExtractCommandHint(reason: reason, nextCommand: next))
    }
}

extension URL {
    var isSupportedAudioExtractLocalFile: Bool {
        guard isFileURL else { return false }
        let ext = pathExtension.lowercased()
        let supported = ["mp4", "mov", "mkv", "webm", "mp3"]
        if supported.contains(ext) {
            return true
        }

        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .movie) || type.conforms(to: .audio)
        }
        return false
    }
}
