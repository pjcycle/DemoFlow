import Foundation

@MainActor
final class VideoConversionService {
    private let binaryService = FFmpegBinaryService()
    private let fileManager = FileManager.default
    private var activeProcess: Process?

    func stopCurrentTask() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    func probeSourceDuration(for sourceURL: URL) throws -> Double {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw VideoConversionError.inputUnavailable
        }
        let tools = try binaryService.ensureReady()
        let command = VideoConversionProbeCommand(
            executableURL: tools.ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourceURL.path
            ]
        )
        let output = try runProbe(command)
        let duration = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first ?? 0
        guard duration > 0 else { throw VideoConversionError.outputValidationFailed }
        return duration
    }

    func convert(
        sourceURL: URL,
        outputURL: URL,
        format: VideoConversionFormat,
        quality: VideoConversionQualityPreset,
        duration: Double,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw VideoConversionError.inputUnavailable
        }

        let tools: FFmpegToolPaths
        do {
            tools = try binaryService.ensureReady()
        } catch {
            throw VideoConversionError.dependenciesUnavailable
        }

        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let command = VideoConversionCommand(
            executableURL: tools.ffmpegURL,
            arguments: makeArguments(
                sourceURL: sourceURL,
                outputURL: outputURL,
                format: format,
                quality: quality
            ),
            duration: duration
        )
        onLog("[ready] ffmpeg=\(tools.ffmpegURL.path)")
        onLog("[ready] ffprobe=\(tools.ffprobeURL.path)")
        onLog("[run] \(command.rendered)")

        do {
            _ = try await runProcess(
                command: command,
                onProgress: onProgress,
                onLog: onLog
            )
        } catch let error as VideoConversionProcessError {
            switch error {
            case .cancelled:
                throw VideoConversionError.cancelled
            case let .launchFailed(reason):
                throw VideoConversionError.launchFailed(reason)
            case let .commandFailed(message):
                throw VideoConversionError.commandFailed(message)
            }
        }

        try validateOutput(
            outputURL: outputURL,
            ffprobeURL: tools.ffprobeURL,
            onLog: onLog
        )
        onProgress(1)
    }

    private func makeArguments(
        sourceURL: URL,
        outputURL: URL,
        format: VideoConversionFormat,
        quality: VideoConversionQualityPreset
    ) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-map_metadata", "0",
        ]

        switch format {
        case .mp4, .mov:
            arguments += [
                "-c:v", "libx264",
                "-preset", "medium",
                "-b:v", "\(quality.videoBitrateMbps)M",
                "-maxrate", "\(quality.videoBitrateMbps)M",
                "-bufsize", "\(quality.videoBitrateMbps * 2)M",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "\(quality.audioBitrateKbps)k",
                "-movflags", "+faststart"
            ]
        case .webm:
            arguments += [
                "-c:v", "libvpx-vp9",
                "-b:v", "\(quality.videoBitrateMbps)M",
                "-deadline", "good",
                "-cpu-used", "2",
                "-c:a", "libopus",
                "-b:a", "\(quality.audioBitrateKbps)k"
            ]
        }

        arguments += [
            "-progress", "pipe:1",
            "-nostats",
            "-f", format.rawValue,
            outputURL.path
        ]
        return arguments
    }

    private func validateOutput(
        outputURL: URL,
        ffprobeURL: URL,
        onLog: @escaping (String) -> Void
    ) throws {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw VideoConversionError.outputValidationFailed
        }
        let attributes = try fileManager.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            throw VideoConversionError.outputValidationFailed
        }

        let durationCommand = VideoConversionProbeCommand(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                outputURL.path
            ]
        )
        onLog("[verify] \(durationCommand.rendered)")
        let durationOutput = try runProbe(durationCommand)
        let duration = durationOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first ?? 0
        guard duration > 0 else {
            throw VideoConversionError.outputValidationFailed
        }

        let videoTrackCommand = VideoConversionProbeCommand(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=codec_type",
                "-of", "default=noprint_wrappers=1:nokey=1",
                outputURL.path
            ]
        )
        let videoTrackOutput = try runProbe(videoTrackCommand)
        guard videoTrackOutput.contains("video") else {
            throw VideoConversionError.outputValidationFailed
        }
    }

    private func runProbe(_ command: VideoConversionProbeCommand) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw VideoConversionError.launchFailed(error.localizedDescription)
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw VideoConversionError.commandFailed(text)
        }
        return text
    }

    private func runProcess(
        command: VideoConversionCommand,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws -> VideoConversionProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let output = VideoConversionOutputCapture()

            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                output.appendStdout(text)
                output.consumeProgress(text, duration: command.duration, onProgress: onProgress)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                output.appendStderr(text)
                text.split(whereSeparator: \.isNewline).map(String.init).forEach { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onLog("[ffmpeg] \(trimmed)") }
                }
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let result = VideoConversionProcessResult(
                    stdout: output.stdout,
                    stderr: output.stderr,
                    exitCode: process.terminationStatus
                )
                Task { @MainActor [weak self] in
                    self?.activeProcess = nil
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: result)
                    } else if process.terminationStatus == 15 || Task.isCancelled {
                        continuation.resume(throwing: VideoConversionProcessError.cancelled)
                    } else {
                        let message = result.stderr.isEmpty ? result.stdout : result.stderr
                        continuation.resume(throwing: VideoConversionProcessError.commandFailed(message))
                    }
                }
            }

            do {
                try process.run()
                activeProcess = process
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: VideoConversionProcessError.launchFailed(error.localizedDescription))
            }
        }
    }
}

enum VideoConversionError: Error {
    case inputUnavailable
    case dependenciesUnavailable
    case outputValidationFailed
    case cancelled
    case launchFailed(String)
    case commandFailed(String)
}

private struct VideoConversionCommand {
    let executableURL: URL
    let arguments: [String]
    let duration: Double

    var rendered: String {
        let arguments = self.arguments.map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
        return "\(executableURL.path) \(arguments)"
    }
}

private struct VideoConversionProbeCommand {
    let executableURL: URL
    let arguments: [String]

    var rendered: String {
        let arguments = self.arguments.map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
        return "\(executableURL.path) \(arguments)"
    }
}

private struct VideoConversionProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private enum VideoConversionProcessError: Error {
    case cancelled
    case launchFailed(String)
    case commandFailed(String)
}

private final class VideoConversionOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var stdoutText = ""
    nonisolated(unsafe) private var stderrText = ""
    nonisolated(unsafe) private var progressBuffer = ""

    nonisolated var stdout: String { lock.withLock { stdoutText } }
    nonisolated var stderr: String { lock.withLock { stderrText } }

    nonisolated func appendStdout(_ text: String) {
        lock.withLock { stdoutText.append(text) }
    }

    nonisolated func appendStderr(_ text: String) {
        lock.withLock { stderrText.append(text) }
    }

    nonisolated func consumeProgress(
        _ text: String,
        duration: Double,
        onProgress: (Double) -> Void
    ) {
        guard duration > 0 else { return }
        let values: [Double] = lock.withLock {
            progressBuffer.append(text)
            var values: [Double] = []
            while let newline = progressBuffer.firstIndex(of: "\n") {
                let line = String(progressBuffer[..<newline])
                progressBuffer.removeSubrange(progressBuffer.startIndex...newline)
                guard line.hasPrefix("out_time_ms=") else { continue }
                let value = line.split(separator: "=", maxSplits: 1).last.flatMap { Double($0) } ?? 0
                values.append(min(max(value / 1_000_000 / duration, 0), 1))
            }
            return values
        }
        values.forEach(onProgress)
    }
}
