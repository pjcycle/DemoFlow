//
//  AudioTranscodeService.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import Foundation

@MainActor
final class AudioTranscodeService {
    private let ffmpegBinaryService = FFmpegBinaryService()
    private let fileManager = FileManager.default
    private var activeProcess: Process?

    func stopCurrentTask() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    func convert(
        sourceURL: URL,
        outputFormat: AudioTranscodeOutputFormat,
        quality: AudioTranscodeQualityPreset,
        outputURL: URL,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioTranscodeResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AudioTranscodeError.conversionFailed(
                AudioToolCommandHint(
                    reason: L10n.tr("audio.import.error.access"),
                    nextCommand: "ls -la \"\(sourceURL.path)\""
                )
            )
        }

        let tools: FFmpegToolPaths
        do {
            tools = try ffmpegBinaryService.ensureReady()
            onLog("[ready] ffmpeg=\(tools.ffmpegURL.path)")
            onLog("[ready] ffprobe=\(tools.ffprobeURL.path)")
        } catch {
            throw AudioTranscodeError.dependenciesUnavailable(
                AudioToolCommandHint(
                    reason: L10n.tr("audio.extract.reason.ffmpeg_missing"),
                    nextCommand: "请使用发布版内置 ffmpeg/ffprobe，或联系开发者检查包体资源是否完整"
                )
            )
        }

        try? fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let arguments = makeArguments(
            sourcePath: sourceURL.path,
            outputPath: outputURL.path,
            outputFormat: outputFormat,
            quality: quality
        )
        let command = AudioTranscodeProcessCommand(executableURL: tools.ffmpegURL, arguments: arguments)
        onLog("[run] \(command.rendered)")

        do {
            _ = try await runProcess(command: command, onLog: onLog)
        } catch let error as AudioTranscodeProcessRunnerError {
            throw AudioTranscodeError.conversionFailed(
                classifyFailure(
                    error: error,
                    sourcePath: sourceURL.path,
                    outputPath: outputURL.path,
                    outputFormat: outputFormat,
                    quality: quality
                )
            )
        }

        return try validateOutput(outputURL: outputURL, outputFormat: outputFormat, ffprobeURL: tools.ffprobeURL, onLog: onLog)
    }

    private func makeArguments(
        sourcePath: String,
        outputPath: String,
        outputFormat: AudioTranscodeOutputFormat,
        quality: AudioTranscodeQualityPreset
    ) -> [String] {
        var args = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", sourcePath,
            "-vn"
        ]

        switch outputFormat {
        case .mp3:
            args += ["-c:a", "libmp3lame", "-b:a", quality.bitrateArgument]
        case .wav:
            args += ["-c:a", "pcm_s16le"]
        case .m4a:
            args += ["-c:a", "aac", "-b:a", quality.bitrateArgument]
        case .flac:
            args += ["-c:a", "flac"]
        }

        args.append(outputPath)
        return args
    }

    private func validateOutput(
        outputURL: URL,
        outputFormat: AudioTranscodeOutputFormat,
        ffprobeURL: URL,
        onLog: @escaping (String) -> Void
    ) throws -> AudioTranscodeResult {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw AudioTranscodeError.outputValidationFailed
        }

        let attrs = try fileManager.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw AudioTranscodeError.outputValidationFailed
        }

        let duration = try probeDuration(outputURL: outputURL, ffprobeURL: ffprobeURL, onLog: onLog)
        guard duration > 0 else {
            throw AudioTranscodeError.outputValidationFailed
        }

        return AudioTranscodeResult(
            outputURL: outputURL,
            outputFormat: outputFormat,
            byteCount: fileSize,
            duration: duration
        )
    }

    private func probeDuration(
        outputURL: URL,
        ffprobeURL: URL,
        onLog: @escaping (String) -> Void
    ) throws -> Double {
        let command = AudioTranscodeProcessCommand(
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

    private func classifyFailure(
        error: AudioTranscodeProcessRunnerError,
        sourcePath: String,
        outputPath: String,
        outputFormat: AudioTranscodeOutputFormat,
        quality: AudioTranscodeQualityPreset
    ) -> AudioToolCommandHint {
        let lowercased = error.combinedOutput.lowercased()
        if lowercased.contains("no such file") || lowercased.contains("not found") {
            return AudioToolCommandHint(
                reason: L10n.tr("audio.import.error.access"),
                nextCommand: "ls -la \"\(sourcePath)\""
            )
        }

        let nextCommand: String
        switch outputFormat {
        case .mp3:
            nextCommand = "ffmpeg -i \"\(sourcePath)\" -vn -c:a libmp3lame -b:a \(quality.bitrateArgument) \"\(outputPath)\""
        case .wav:
            nextCommand = "ffmpeg -i \"\(sourcePath)\" -vn -c:a pcm_s16le \"\(outputPath)\""
        case .m4a:
            nextCommand = "ffmpeg -i \"\(sourcePath)\" -vn -c:a aac -b:a \(quality.bitrateArgument) \"\(outputPath)\""
        case .flac:
            nextCommand = "ffmpeg -i \"\(sourcePath)\" -vn -c:a flac \"\(outputPath)\""
        }

        return AudioToolCommandHint(reason: error.shortReason, nextCommand: nextCommand)
    }

    private func runProcess(
        command: AudioTranscodeProcessCommand,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioTranscodeProcessRunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let outputBuffer = AudioTranscodeProcessOutputBuffer()

            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.standardOutput = stdout
            process.standardError = stderr
            let clearActiveProcess: @MainActor @Sendable () -> Void = { [weak self] in
                self?.activeProcess = nil
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                outputBuffer.appendStdout(text)
                text.split(whereSeparator: \.isNewline).map(String.init).forEach { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onLog("[ffmpeg] \(trimmed)")
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                outputBuffer.appendStderr(text)
                text.split(whereSeparator: \.isNewline).map(String.init).forEach { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onLog("[ffmpeg] \(trimmed)")
                    }
                }
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let snapshot = outputBuffer.snapshot()
                let result = AudioTranscodeProcessRunResult(
                    stdout: snapshot.stdout,
                    stderr: snapshot.stderr,
                    exitCode: process.terminationStatus
                )
                Task { @MainActor in
                    clearActiveProcess()
                    if process.terminationReason == .uncaughtSignal || process.terminationStatus != 0 {
                        if Task.isCancelled || process.terminationStatus == 15 {
                            continuation.resume(throwing: AudioTranscodeError.cancelled)
                        } else {
                            continuation.resume(throwing: AudioTranscodeProcessRunnerError.commandFailed(
                                stdout: result.stdout,
                                stderr: result.stderr,
                                exitCode: result.exitCode
                            ))
                        }
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }

            do {
                try process.run()
                activeProcess = process
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: AudioTranscodeProcessRunnerError.launchFailed(error.localizedDescription))
            }
        }
    }

    private func runProcessSync(command: AudioTranscodeProcessCommand) throws -> AudioTranscodeProcessRunResult {
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
            throw AudioTranscodeProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let result = AudioTranscodeProcessRunResult(stdout: stdoutText, stderr: stderrText, exitCode: process.terminationStatus)
        if process.terminationStatus != 0 {
            throw AudioTranscodeProcessRunnerError.commandFailed(
                stdout: stdoutText,
                stderr: stderrText,
                exitCode: process.terminationStatus
            )
        }
        return result
    }
}

private struct AudioTranscodeProcessCommand {
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

private struct AudioTranscodeProcessRunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private final class AudioTranscodeProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var stdoutText = ""
    nonisolated(unsafe) private var stderrText = ""

    nonisolated func appendStdout(_ text: String) {
        lock.lock()
        stdoutText.append(text)
        lock.unlock()
    }

    nonisolated func appendStderr(_ text: String) {
        lock.lock()
        stderrText.append(text)
        lock.unlock()
    }

    nonisolated func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutText, stderrText)
    }
}

private enum AudioTranscodeProcessRunnerError: Error {
    case launchFailed(String)
    case commandFailed(stdout: String, stderr: String, exitCode: Int32)

    var combinedOutput: String {
        switch self {
        case let .launchFailed(message):
            return message
        case let .commandFailed(stdout, stderr, _):
            return [stdout, stderr].joined(separator: "\n")
        }
    }

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
