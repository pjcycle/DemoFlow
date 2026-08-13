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
    private let ffmpegBinaryService = FFmpegBinaryService()

    func preparedAsset(from url: URL) async throws -> AudioPreparedAsset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioImportError.fileNotAccessible
        }

        let metadata: AudioMetadata
        do {
            metadata = try await avFoundationMetadata(from: url)
        } catch {
            // Some valid MP3 files are decodable by FFmpeg but do not expose a
            // complete AVFoundation stream description. Do not reject them.
            metadata = try ffprobeMetadata(from: url)
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = values?.fileSize.map(Int64.init) ?? 0
        let displayName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        return AudioPreparedAsset(
            sourceURL: url,
            displayName: displayName,
            duration: metadata.duration,
            sampleRate: metadata.sampleRate,
            channelCount: metadata.channelCount,
            sourceByteCount: byteCount,
            sourceFormatHint: formatHint(for: ext)
        )
    }

    private func avFoundationMetadata(from url: URL) async throws -> AudioMetadata {
        let asset = AVAssetAsyncLoaders.makeURLAsset(url)
        let duration = try await AVAssetAsyncLoaders.duration(of: asset).seconds
        guard duration.isFinite, duration > 0,
              let audioTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio) else {
            throw AudioImportError.metadataFailed
        }
        let (sampleRate, channelCount) = try await audioStreamDescription(for: audioTrack, fallbackURL: url)
        return AudioMetadata(duration: duration, sampleRate: sampleRate, channelCount: channelCount)
    }

    private func ffprobeMetadata(from url: URL) throws -> AudioMetadata {
        let tools = try ffmpegBinaryService.ensureReady()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = tools.ffprobeURL
        process.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "format=duration:stream=sample_rate,channels",
            "-of", "json",
            url.path
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AudioImportError.metadataFailed
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let response = try? JSONDecoder().decode(FFprobeResponse.self, from: data),
              let stream = response.streams.first,
              let duration = Double(response.format.duration), duration.isFinite, duration > 0,
              let sampleRate = Double(stream.sampleRate), sampleRate > 0,
              let channelCount = stream.channels, channelCount > 0 else {
            throw AudioImportError.metadataFailed
        }

        return AudioMetadata(duration: duration, sampleRate: sampleRate, channelCount: channelCount)
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

private struct AudioMetadata {
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
}

private struct FFprobeResponse: Decodable {
    let streams: [FFprobeAudioStream]
    let format: FFprobeFormat
}

private struct FFprobeAudioStream: Decodable {
    let sampleRate: String
    let channels: Int?

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
    }
}

private struct FFprobeFormat: Decodable {
    let duration: String
}
