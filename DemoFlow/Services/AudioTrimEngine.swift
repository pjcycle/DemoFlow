//
//  AudioTrimEngine.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import AVFoundation
import Foundation

@MainActor
final class AudioTrimEngine {
    private let ffmpegBinaryService = FFmpegBinaryService()
    private let fileManager = FileManager.default

    func exportAvailability(for preferredOutputFormat: AudioTranscodeOutputFormat?) -> AudioTrimExportAvailability {
        guard let preferredOutputFormat else {
            return .blocked(reason: L10n.tr("audio.trim.error.no_source"))
        }
        return .allowed(formatLabel: preferredOutputFormat.displayName)
    }

    func makePreviewURL(
        preparedAsset: AudioPreparedAsset,
        range: AudioTrimRange
    ) async throws -> URL {
        let outputURL = temporaryURL(directoryName: "demoflow-audio-trim-preview", fileExtension: "m4a")
        let segment = AudioTrimSegment(startTime: range.startTime, endTime: range.endTime)
        try await exportSegmentsToM4A(preparedAsset: preparedAsset, segments: [segment], outputURL: outputURL)
        return outputURL
    }

    func makeWorkingCopyURL(
        preparedAsset: AudioPreparedAsset,
        remainingSegments: [AudioTrimSegment]
    ) async throws -> URL {
        let outputURL = temporaryURL(directoryName: "demoflow-audio-trim-working", fileExtension: "m4a")
        try await exportSegmentsToM4A(preparedAsset: preparedAsset, segments: remainingSegments, outputURL: outputURL)
        return outputURL
    }

    func exportCurrentAsset(
        preparedAsset: AudioPreparedAsset,
        outputFormat: AudioTranscodeOutputFormat,
        outputURL: URL,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioTrimExportResult {
        switch outputFormat {
        case .m4a:
            try await exportAssetToM4A(sourceURL: preparedAsset.sourceURL, outputURL: outputURL)
        case .mp3, .wav, .flac:
            try await exportAssetWithFFmpeg(
                sourceURL: preparedAsset.sourceURL,
                outputFormat: outputFormat,
                outputURL: outputURL,
                onLog: onLog
            )
        }

        return try validateOutput(outputURL: outputURL, onLog: onLog)
    }

    private func exportSegmentsToM4A(
        preparedAsset: AudioPreparedAsset,
        segments: [AudioTrimSegment],
        outputURL: URL
    ) async throws {
        let asset = AVAssetAsyncLoaders.makeURLAsset(preparedAsset.sourceURL)
        guard let sourceTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio) else {
            throw AudioTrimError.exportUnavailable(L10n.tr("audio.trim.error.no_audio_track"))
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioTrimError.exportUnavailable(L10n.tr("audio.trim.error.export_unavailable"))
        }

        var cursor = CMTime.zero
        for segment in segments {
            let start = CMTime(seconds: segment.startTime, preferredTimescale: 600)
            let end = CMTime(seconds: segment.endTime, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            try compositionTrack.insertTimeRange(range, of: sourceTrack, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }

        try? fileManager.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioTrimError.exportUnavailable(L10n.tr("audio.trim.error.export_unavailable"))
        }
        try await AVAssetAsyncLoaders.export(exporter, outputURL: outputURL, outputFileType: .m4a)
    }

    private func exportAssetToM4A(sourceURL: URL, outputURL: URL) async throws {
        let asset = AVAssetAsyncLoaders.makeURLAsset(sourceURL)
        try? fileManager.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioTrimError.exportUnavailable(L10n.tr("audio.trim.error.export_unavailable"))
        }
        try await AVAssetAsyncLoaders.export(exporter, outputURL: outputURL, outputFileType: .m4a)
    }

    private func exportAssetWithFFmpeg(
        sourceURL: URL,
        outputFormat: AudioTranscodeOutputFormat,
        outputURL: URL,
        onLog: @escaping (String) -> Void
    ) async throws {
        let tools: FFmpegToolPaths
        do {
            tools = try ffmpegBinaryService.ensureReady()
            onLog("[ready] ffmpeg=\(tools.ffmpegURL.path)")
            onLog("[ready] ffprobe=\(tools.ffprobeURL.path)")
        } catch {
            throw AudioTrimError.exportFailed(
                AudioToolCommandHint(
                    reason: L10n.tr("audio.extract.reason.ffmpeg_missing"),
                    nextCommand: "请使用发布版内置 ffmpeg/ffprobe，或联系开发者检查包体资源是否完整"
                )
            )
        }

        try? fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", sourceURL.path,
            "-vn"
        ]

        switch outputFormat {
        case .mp3:
            arguments += ["-c:a", "libmp3lame", "-b:a", "192k"]
        case .wav:
            arguments += ["-c:a", "pcm_s16le"]
        case .m4a:
            arguments += ["-c:a", "aac", "-b:a", "192k"]
        case .flac:
            arguments += ["-c:a", "flac"]
        }

        arguments.append(outputURL.path)
        let command = AudioTrimProcessCommand(executableURL: tools.ffmpegURL, arguments: arguments)
        onLog("[run] \(command.rendered)")

        do {
            _ = try runProcessSync(command: command)
        } catch let error as AudioTrimProcessRunnerError {
            throw AudioTrimError.exportFailed(
                AudioToolCommandHint(
                    reason: error.shortReason,
                    nextCommand: command.rendered
                )
            )
        }
    }

    private func validateOutput(
        outputURL: URL,
        onLog: @escaping (String) -> Void
    ) throws -> AudioTrimExportResult {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw AudioTrimError.outputValidationFailed
        }
        let attrs = try fileManager.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw AudioTrimError.outputValidationFailed
        }

        let tools = try ffmpegBinaryService.ensureReady()
        let duration = try probeDuration(outputURL: outputURL, ffprobeURL: tools.ffprobeURL, onLog: onLog)
        guard duration > 0 else {
            throw AudioTrimError.outputValidationFailed
        }

        return AudioTrimExportResult(outputURL: outputURL, duration: duration, byteCount: fileSize)
    }

    private func probeDuration(outputURL: URL, ffprobeURL: URL, onLog: @escaping (String) -> Void) throws -> Double {
        let command = AudioTrimProcessCommand(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                outputURL.path
            ]
        )
        onLog("[verify] \(command.rendered)")
        let result = try runProcessSync(command: command)
        let merged = result.stdout + "\n" + result.stderr
        let firstLine = merged
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Double(firstLine) ?? 0
    }

    private func temporaryURL(directoryName: String, fileExtension: String) -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    private func runProcessSync(command: AudioTrimProcessCommand) throws -> AudioTrimProcessRunResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AudioTrimProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw AudioTrimProcessRunnerError.commandFailed(
                stdout: stdoutText,
                stderr: stderrText,
                exitCode: process.terminationStatus
            )
        }
        return AudioTrimProcessRunResult(stdout: stdoutText, stderr: stderrText, exitCode: process.terminationStatus)
    }
}

private struct AudioTrimProcessCommand {
    let executableURL: URL
    let arguments: [String]

    var rendered: String {
        let head = executableURL.path
        let tail = arguments.map { argument in
            if argument.contains(" ") {
                return "\"\(argument)\""
            }
            return argument
        }.joined(separator: " ")
        return "\(head) \(tail)"
    }
}

private struct AudioTrimProcessRunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private enum AudioTrimProcessRunnerError: Error {
    case launchFailed(String)
    case commandFailed(stdout: String, stderr: String, exitCode: Int32)

    var shortReason: String {
        switch self {
        case let .launchFailed(message):
            return message
        case let .commandFailed(_, stderr, exitCode):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            return "exit=\(exitCode)"
        }
    }
}
