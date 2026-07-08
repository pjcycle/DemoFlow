//
//  AudioPreparedAsset.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import Foundation
import UniformTypeIdentifiers

struct AudioPreparedAsset {
    let sourceURL: URL
    let displayName: String
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let sourceByteCount: Int64
    let sourceFormatHint: String

    var durationText: String {
        formatTime(duration)
    }

    var sampleRateText: String {
        if sampleRate <= 0 {
            return "--"
        }
        return String(format: "%.0f Hz", sampleRate)
    }

    var channelCountText: String {
        switch channelCount {
        case ..<1:
            return "--"
        case 1:
            return L10n.tr("audio.meta.channel.mono")
        case 2:
            return L10n.tr("audio.meta.channel.stereo")
        default:
            return L10n.f("audio.meta.channel.multi", channelCount)
        }
    }

    var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: sourceByteCount, countStyle: .file)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct AudioToolCommandHint {
    let reason: String
    let nextCommand: String

    var combinedMessage: String {
        "\(L10n.tr("audio.tool.error.reason")) \(reason)\n\(L10n.tr("audio.tool.error.next")) \(nextCommand)"
    }
}

enum AudioImportError: LocalizedError {
    case unsupportedType
    case fileNotAccessible
    case metadataFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return L10n.tr("audio.import.error.unsupported")
        case .fileNotAccessible:
            return L10n.tr("audio.import.error.access")
        case .metadataFailed:
            return L10n.tr("audio.import.error.metadata")
        }
    }
}

enum AudioPreviewStatus: Equatable {
    case idle
    case playing
    case paused
    case failed(String)
}

enum AudioFileKind {
    case anyAudio

    var allowedTypes: [UTType] {
        var types: [UTType] = [.mp3, .wav, .aiff, .mpeg4Audio]
        if let flac = UTType(filenameExtension: "flac") {
            types.append(flac)
        }
        if let aac = UTType(filenameExtension: "aac") {
            types.append(aac)
        }
        return types
    }
}

extension URL {
    var isSupportedAudioToolLocalFile: Bool {
        guard isFileURL else { return false }
        let ext = pathExtension.lowercased()
        let supported = ["mp3", "wav", "wave", "aiff", "aif", "m4a", "aac", "flac"]
        if supported.contains(ext) {
            return true
        }

        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .audio)
        }
        return false
    }
}
