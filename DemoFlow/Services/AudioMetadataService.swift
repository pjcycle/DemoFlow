//
//  AudioMetadataService.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import AVFoundation
import CoreMedia
import Foundation

final class AudioMetadataService {
    func preparedAsset(from url: URL) async throws -> AudioPreparedAsset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioImportError.fileNotAccessible
        }

        let asset = AVAssetAsyncLoaders.makeURLAsset(url)
        let duration = try await AVAssetAsyncLoaders.duration(of: asset).seconds
        guard let audioTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio) else {
            throw AudioImportError.metadataFailed
        }
        let (sampleRate, channelCount) = try await audioStreamDescription(for: audioTrack, fallbackURL: url)

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = values?.fileSize.map(Int64.init) ?? 0
        let displayName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        return AudioPreparedAsset(
            sourceURL: url,
            displayName: displayName,
            duration: max(duration, 0),
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceByteCount: byteCount,
            sourceFormatHint: formatHint(for: ext)
        )
    }

    private func audioStreamDescription(
        for track: AVAssetTrack,
        fallbackURL: URL
    ) async throws -> (sampleRate: Double, channelCount: Int) {
        let formatDescriptions = try await track.load(.formatDescriptions)
        for description in formatDescriptions {
            guard let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                continue
            }

            let sampleRate = streamBasicDescription.mSampleRate
            let channelCount = Int(streamBasicDescription.mChannelsPerFrame)
            if sampleRate > 0, channelCount > 0 {
                return (sampleRate, channelCount)
            }
        }

        // Some local PCM files expose richer metadata through AVAudioFile; keep it as a fallback only.
        if let audioFile = try? AVAudioFile(forReading: fallbackURL) {
            return (audioFile.fileFormat.sampleRate, Int(audioFile.fileFormat.channelCount))
        }

        throw AudioImportError.metadataFailed
    }

    private func formatHint(for ext: String) -> String {
        switch ext {
        case "mp3":
            return "MP3"
        case "wav", "wave":
            return "WAV"
        case "aiff", "aif":
            return "AIFF"
        case "m4a":
            return "M4A"
        case "aac":
            return "AAC"
        case "flac":
            return "FLAC"
        default:
            return ext.uppercased()
        }
    }
}
