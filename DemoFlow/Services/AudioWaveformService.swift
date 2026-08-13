//
//  AudioWaveformService.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import CoreGraphics
import Foundation

final class AudioWaveformService {
    nonisolated private let ffmpegBinaryService = FFmpegBinaryService()
    nonisolated private let fileManager = FileManager.default

    nonisolated func loadWaveformSamples(from url: URL, sampleCount: Int = 180) async throws -> [CGFloat] {
        let targetCount = max(sampleCount, 60)
        let task = Task.detached(priority: .userInitiated) { [self] in
            let tools = try await MainActor.run { try self.ffmpegBinaryService.ensureReady() }
            // Sandbox apps need a security scope to read user-configured
            // output directories outside the container.
            let isAccessingScope = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessingScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let pcmURL = try self.makeTemporaryPCMURL()
            defer {
                try? self.fileManager.removeItem(at: pcmURL)
            }

            let process = Process()

            process.executableURL = tools.ffmpegURL
            process.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-i", url.path,
                "-vn",
                "-ac", "1",
                "-ar", "1000",
                "-f", "f32le",
                "-y",
                pcmURL.path
            ]

            // Decoding a full track to a Pipe and waiting before reading it can
            // deadlock once the pipe buffer fills. Use a short-lived PCM file
            // instead so long MP3 files import just like other audio formats.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw AudioImportError.metadataFailed
            }

            guard process.terminationStatus == 0 else {
                throw AudioImportError.metadataFailed
            }

            let data = try Data(contentsOf: pcmURL, options: .mappedIfSafe)
            guard data.count >= MemoryLayout<Float>.size else {
                return Self.placeholderSamples(count: targetCount)
            }

            let sampleValueCount = data.count / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: sampleValueCount)
            _ = samples.withUnsafeMutableBytes { rawBuffer in
                data.copyBytes(to: rawBuffer)
            }

            guard !samples.isEmpty else {
                return Self.placeholderSamples(count: targetCount)
            }

            var bins = [Float](repeating: 0, count: targetCount)
            for (index, sample) in samples.enumerated() {
                let progress = Double(index) / Double(max(samples.count - 1, 1))
                let binIndex = min(max(Int(progress * Double(targetCount)), 0), targetCount - 1)
                bins[binIndex] = max(bins[binIndex], abs(sample))
            }
            let maxAmplitude = max(bins.max() ?? 0, 0.001)
            return bins.map { raw in
                let normalized = CGFloat(raw / maxAmplitude)
                return min(max(normalized, 0.06), 1.0)
            }
        }
        return try await task.value
    }

    nonisolated private func makeTemporaryPCMURL() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("demoflow-audio-waveforms", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("f32")
    }

    nonisolated static func placeholderSamples(count: Int = 180) -> [CGFloat] {
        [CGFloat](repeating: 0.12, count: max(count, 60))
    }
}
