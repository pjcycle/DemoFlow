//
//  FFmpegRunner.swift
//  DemoFlow
//
//  Created by Codex on 2026/5/12.
//

import Foundation

private struct FFmpegLocalizedErrorFormatter {
    @MainActor
    static func launchFailed(_ reason: String) -> String {
        L10n.f("fmt.ffmpeg.launch_failed", reason)
    }

    @MainActor
    static func commandFailed(exitCode: Int32, message: String) -> String {
        L10n.f("fmt.ffmpeg.command_failed", exitCode, message)
    }
}

nonisolated final class FFmpegRunner {
    func run(
        command: FFmpegCommand,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> FFmpegExecutionResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let captureState = FFmpegOutputCaptureState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            captureState.appendStdout(text)
            captureState.consumeProgress(from: text, expectedDurationSeconds: command.expectedDurationSeconds) { ratio in
                onProgress?(ratio)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            captureState.appendStderr(String(decoding: data, as: UTF8.self))
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !stdoutTail.isEmpty {
                    captureState.appendStdout(String(decoding: stdoutTail, as: UTF8.self))
                }
                let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !stderrTail.isEmpty {
                    captureState.appendStderr(String(decoding: stderrTail, as: UTF8.self))
                }

                let result = FFmpegExecutionResult(
                    stdout: captureState.stdout,
                    stderr: captureState.stderr,
                    exitCode: process.terminationStatus
                )

                if process.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: FFmpegRunnerError.commandFailed(result))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: FFmpegRunnerError.launchFailed(error.localizedDescription))
            }
        }
    }
}

nonisolated private final class FFmpegOutputCaptureState: @unchecked Sendable {
    private static let maxStdoutChars = 256_000
    private static let maxStderrChars = 256_000
    private static let maxProgressBufferChars = 65_536

    private let lock = NSLock()
    private var stdoutText = ""
    private var stderrText = ""
    private var progressLineBuffer = ""

    var stdout: String {
        lock.withLock { stdoutText }
    }

    var stderr: String {
        lock.withLock { stderrText }
    }

    func appendStdout(_ text: String) {
        lock.withLock {
            stdoutText.append(text)
            if stdoutText.count > Self.maxStdoutChars {
                stdoutText = String(stdoutText.suffix(Self.maxStdoutChars))
            }
        }
    }

    func appendStderr(_ text: String) {
        lock.withLock {
            stderrText.append(text)
            if stderrText.count > Self.maxStderrChars {
                stderrText = String(stderrText.suffix(Self.maxStderrChars))
            }
        }
    }

    func consumeProgress(
        from text: String,
        expectedDurationSeconds: Double?,
        onProgress: (Double) -> Void
    ) {
        guard let expectedDurationSeconds, expectedDurationSeconds > 0 else { return }
        let ratios: [Double] = lock.withLock {
            progressLineBuffer.append(text)
            if progressLineBuffer.count > Self.maxProgressBufferChars {
                progressLineBuffer = String(progressLineBuffer.suffix(Self.maxProgressBufferChars))
            }
            var parsedRatios: [Double] = []
            while let index = progressLineBuffer.firstIndex(of: "\n") {
                let line = String(progressLineBuffer[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                progressLineBuffer.removeSubrange(progressLineBuffer.startIndex...index)
                guard line.hasPrefix("out_time_ms="),
                      let msValue = line.split(separator: "=", maxSplits: 1).last,
                      let ms = Double(msValue) else {
                    continue
                }
                let ratio = max(0, min(1, (ms / 1_000_000.0) / expectedDurationSeconds))
                parsedRatios.append(ratio)
            }
            return parsedRatios
        }
        ratios.forEach(onProgress)
    }
}

extension FFmpegRunner {
    enum FFmpegRunnerError: Error {
        case launchFailed(String)
        case commandFailed(FFmpegExecutionResult)
    }
}

extension FFmpegRunner.FFmpegRunnerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .launchFailed(reason):
            return MainActor.assumeIsolated {
                FFmpegLocalizedErrorFormatter.launchFailed(reason)
            }
        case let .commandFailed(result):
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            return MainActor.assumeIsolated {
                FFmpegLocalizedErrorFormatter.commandFailed(exitCode: result.exitCode, message: message)
            }
        }
    }
}
