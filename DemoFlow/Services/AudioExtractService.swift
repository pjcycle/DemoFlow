//
//  AudioExtractService.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/12.
//

import Foundation

@MainActor
final class AudioExtractService {
    private let ffmpegBinaryService = FFmpegBinaryService()
    private let ytDlpBinaryService = YtDlpBinaryService()
    private let fileManager = FileManager.default
    private var activeProcess: Process?

    func stopCurrentTask() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    func extract(
        sourceType: AudioExtractSourceType,
        localFileURL: URL?,
        sourceURLString: String,
        quality: AudioExtractQualityPreset,
        outputRootURL: URL,
        installDeps: Bool,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioExtractResult {
        switch sourceType {
        case .localFile:
            guard let localFileURL else {
                throw AudioExtractServiceError.missingInput
            }
            return try await extractFromLocalFile(
                localFileURL: localFileURL,
                quality: quality,
                outputRootURL: outputRootURL,
                onLog: onLog
            )
        case .onlineURL:
            return try await extractFromOnlineURL(
                sourceURLString: sourceURLString,
                quality: quality,
                outputRootURL: outputRootURL,
                installDeps: installDeps,
                onLog: onLog
            )
        }
    }

    private func extractFromLocalFile(
        localFileURL: URL,
        quality: AudioExtractQualityPreset,
        outputRootURL: URL,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioExtractResult {
        guard localFileURL.isSupportedAudioExtractLocalFile else {
            throw AudioExtractServiceError.unsupportedLocalFile
        }
        guard fileManager.fileExists(atPath: localFileURL.path) else {
            throw AudioExtractServiceError.localExtractionFailed(
                AudioExtractCommandHint(
                    reason: L10n.tr("audio.extract.reason.local_missing"),
                    nextCommand: "ls -la \"\(localFileURL.path)\""
                )
            )
        }

        let tools: AudioExtractToolchain
        do {
            tools = try await resolveToolchain(
                needsYtDlp: false,
                installDeps: false,
                onLog: onLog
            )
        } catch let error as AudioExtractServiceError {
            throw error
        } catch {
            throw AudioExtractServiceError.dependencyHint(
                error.localizedDescription,
                "请使用发布版内置 ffmpeg/ffprobe，或联系开发者检查包体资源是否完整"
            )
        }

        let outputDirectory = try makeOutputDirectory(root: outputRootURL, sourceTag: sanitizeSourceTag(localFileURL.deletingPathExtension().lastPathComponent))
        let outputFileName = "\(sanitizeSourceTag(localFileURL.deletingPathExtension().lastPathComponent)).mp3"
        let outputMP3URL = outputDirectory.appendingPathComponent(outputFileName)

        let command = ProcessCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", localFileURL.path,
                "-vn",
                "-codec:a", "libmp3lame",
                "-q:a", quality.ffmpegQualityValue,
                outputMP3URL.path
            ]
        )

        onLog("[run] \(command.rendered)")

        do {
            _ = try await runProcess(command: command, onLog: onLog)
        } catch let runnerError as ProcessRunnerError {
            throw AudioExtractServiceError.localExtractionFailed(
                classifyLocalExtractionFailure(
                    runnerError: runnerError,
                    sourcePath: localFileURL.path,
                    outputPath: outputMP3URL.path,
                    quality: quality
                )
            )
        }

        return try validateOutput(
            directory: outputDirectory,
            mp3URL: outputMP3URL,
            ffprobeURL: tools.ffprobeURL,
            onLog: onLog
        )
    }

    private func extractFromOnlineURL(
        sourceURLString: String,
        quality: AudioExtractQualityPreset,
        outputRootURL: URL,
        installDeps: Bool,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioExtractResult {
        guard let parsedURL = URL(string: sourceURLString), parsedURL.scheme != nil else {
            throw AudioExtractServiceError.invalidURL
        }

        let tools: AudioExtractToolchain
        do {
            tools = try await resolveToolchain(
                needsYtDlp: true,
                installDeps: installDeps,
                onLog: onLog
            )
        } catch let error as AudioExtractServiceError {
            throw error
        } catch {
            throw AudioExtractServiceError.dependencyHint(
                L10n.tr("audio.extract.reason.ytdlp_missing"),
                "请使用发布版内置 yt-dlp，或联系开发者检查包体资源是否完整"
            )
        }

        let outputDirectory = try makeOutputDirectory(root: outputRootURL, sourceTag: sourceTagForURL(sourceURLString))
        let templatePath = outputDirectory.appendingPathComponent("%(title).120B-%(id)s.%(ext)s").path

        guard let ytDlpCommand = tools.ytDlpCommand else {
            throw AudioExtractServiceError.dependencyHint(
                L10n.tr("audio.extract.reason.ytdlp_missing"),
                "请使用发布版内置 yt-dlp，或联系开发者检查包体资源是否完整"
            )
        }
        let command = ProcessCommand(
            executableURL: ytDlpCommand.executableURL,
            currentDirectoryURL: ytDlpCommand.workingDirectoryURL,
            environment: ytDlpCommand.environment,
            arguments: ytDlpCommand.makeArguments([
                "--newline",
                "--no-warnings",
                "--restrict-filenames",
                "--ffmpeg-location", tools.ffmpegURL.deletingLastPathComponent().path,
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", quality.ytDlpQualityValue,
                "--output", templatePath,
                sourceURLString
            ])
        )

        onLog("[run] \(command.rendered)")

        do {
            _ = try await runProcess(command: command, onLog: onLog)
        } catch let runnerError as ProcessRunnerError {
            throw AudioExtractServiceError.urlExtractionFailed(
                classifyURLExtractionFailure(
                    runnerError: runnerError,
                    sourceURLString: sourceURLString
                )
            )
        }

        guard let mp3URL = latestMP3(in: outputDirectory) else {
            throw AudioExtractServiceError.urlExtractionFailed(
                AudioExtractCommandHint(
                    reason: L10n.tr("audio.extract.reason.no_output"),
                    nextCommand: "ls -la \"\(outputDirectory.path)\""
                )
            )
        }

        return try validateOutput(
            directory: outputDirectory,
            mp3URL: mp3URL,
            ffprobeURL: tools.ffprobeURL,
            onLog: onLog
        )
    }

    private func validateOutput(
        directory: URL,
        mp3URL: URL,
        ffprobeURL: URL,
        onLog: @escaping (String) -> Void
    ) throws -> AudioExtractResult {
        guard fileManager.fileExists(atPath: mp3URL.path) else {
            throw AudioExtractServiceError.outputValidationFailed
        }

        let attrs = try fileManager.attributesOfItem(atPath: mp3URL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw AudioExtractServiceError.outputValidationFailed
        }

        let duration = try probeDuration(mp3URL: mp3URL, ffprobeURL: ffprobeURL, onLog: onLog)
        guard duration > 0 else {
            throw AudioExtractServiceError.outputValidationFailed
        }

        return AudioExtractResult(outputDirectory: directory, mp3URL: mp3URL, duration: duration)
    }

    private func probeDuration(
        mp3URL: URL,
        ffprobeURL: URL,
        onLog: @escaping (String) -> Void
    ) throws -> Double {
        let command = ProcessCommand(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                mp3URL.path
            ]
        )

        onLog("[verify] \(command.rendered)")
        let result = try runProcessSync(command: command)
        let merged = result.stdout + "\n" + result.stderr
        let trimmed = merged
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Double(trimmed) ?? 0
    }

    private func resolveToolchain(
        needsYtDlp: Bool,
        installDeps: Bool,
        onLog: @escaping (String) -> Void
    ) async throws -> AudioExtractToolchain {
        let ffmpegTools: FFmpegToolPaths
        do {
            ffmpegTools = try ffmpegBinaryService.ensureReady()
            onLog("[ready] ffmpeg=\(ffmpegTools.ffmpegURL.path)")
            onLog("[ready] ffprobe=\(ffmpegTools.ffprobeURL.path)")
        } catch {
            throw AudioExtractServiceError.dependencyHint(
                L10n.tr("audio.extract.reason.ffmpeg_missing"),
                "请使用发布版内置 ffmpeg/ffprobe，或联系开发者检查包体资源是否完整"
            )
        }

        if !needsYtDlp {
            return AudioExtractToolchain(
                ffmpegURL: ffmpegTools.ffmpegURL,
                ffprobeURL: ffmpegTools.ffprobeURL,
                ytDlpCommand: nil
            )
        }

        do {
            let ytDlpCommand = try ytDlpBinaryService.ensureReady()
            onLog("[ready] yt-dlp=\(ytDlpCommand.candidatePath)")
            onLog("[ready] yt-dlp-launch=\(ytDlpCommand.rendered)")
            return AudioExtractToolchain(
                ffmpegURL: ffmpegTools.ffmpegURL,
                ffprobeURL: ffmpegTools.ffprobeURL,
                ytDlpCommand: ytDlpCommand
            )
        } catch let error as YtDlpBinaryService.YtDlpError {
            if case .notIncluded = error {
                throw AudioExtractServiceError.dependencyHint(
                    error.localizedDescription,
                    ""
                )
            }
            onLog("[deps] yt-dlp resolve failed: \(error.localizedDescription)")
        } catch {
            onLog("[deps] yt-dlp resolve failed: \(error.localizedDescription)")
        }

        throw AudioExtractServiceError.dependencyHint(
            L10n.tr("audio.extract.reason.ytdlp_missing"),
            "请使用发布版内置 yt-dlp，或联系开发者检查包体资源是否完整"
        )
    }

    private func makeOutputDirectory(root: URL, sourceTag: String) throws -> URL {
        let safeTag = sourceTag.isEmpty ? "source" : sourceTag
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())

        let dir = root.appendingPathComponent("\(timestamp)_\(safeTag)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AudioExtractServiceError.missingOutputDirectory
        }
        return dir
    }

    private func latestMP3(in directory: URL) -> URL? {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return items
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
    }

    private func sourceTagForURL(_ urlString: String) -> String {
        if let matched = urlString.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) {
            return sanitizeSourceTag(String(urlString[matched]))
        }
        if let matched = urlString.range(of: "[?&]v=([0-9A-Za-z_-]{11})", options: .regularExpression) {
            let segment = String(urlString[matched])
            if let v = segment.split(separator: "=").last {
                return sanitizeSourceTag(String(v))
            }
        }

        let trimmed = urlString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return sanitizeSourceTag(trimmed)
    }

    private func sanitizeSourceTag(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let transformed = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let compacted = String(transformed)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if compacted.isEmpty {
            return "source"
        }
        return String(compacted.prefix(80))
    }

    private func classifyLocalExtractionFailure(
        runnerError: ProcessRunnerError,
        sourcePath: String,
        outputPath: String,
        quality: AudioExtractQualityPreset
    ) -> AudioExtractCommandHint {
        let raw = runnerError.combinedOutput.lowercased()
        if raw.contains("no such file") || raw.contains("not found") {
            return AudioExtractCommandHint(
                reason: L10n.tr("audio.extract.reason.local_missing"),
                nextCommand: "ls -la \"\(sourcePath)\""
            )
        }
        if raw.contains("output file #0 does not contain any stream") || raw.contains("stream map") {
            return AudioExtractCommandHint(
                reason: L10n.tr("audio.extract.reason.no_audio_stream"),
                nextCommand: "ffprobe -hide_banner \"\(sourcePath)\""
            )
        }

        return AudioExtractCommandHint(
            reason: runnerError.shortReason,
            nextCommand: "ffmpeg -i \"\(sourcePath)\" -vn -codec:a libmp3lame -q:a \(quality.ffmpegQualityValue) \"\(outputPath)\""
        )
    }

    private func classifyURLExtractionFailure(
        runnerError: ProcessRunnerError,
        sourceURLString: String
    ) -> AudioExtractCommandHint {
        let raw = runnerError.combinedOutput.lowercased()

        if raw.contains("temporary failure in name resolution") || raw.contains("name or service not known") {
            return AudioExtractCommandHint(
                reason: L10n.tr("audio.extract.reason.network_dns"),
                nextCommand: "yt-dlp --verbose \"\(sourceURLString)\""
            )
        }
        if raw.contains("429") || raw.contains("too many requests") {
            return AudioExtractCommandHint(
                reason: L10n.tr("audio.extract.reason.network_429"),
                nextCommand: "yt-dlp --sleep-requests 2 --verbose \"\(sourceURLString)\""
            )
        }
        if raw.contains("video unavailable") || raw.contains("this video is unavailable") {
            return AudioExtractCommandHint(
                reason: L10n.tr("audio.extract.reason.video_unavailable"),
                nextCommand: "yt-dlp --verbose \"\(sourceURLString)\""
            )
        }
        if raw.contains("unsupported url") {
            return AudioExtractCommandHint(
                reason: L10n.tr("audio.extract.reason.unsupported_url"),
                nextCommand: "yt-dlp --verbose \"\(sourceURLString)\""
            )
        }

        return AudioExtractCommandHint(
            reason: runnerError.shortReason,
            nextCommand: "yt-dlp -x --audio-format mp3 --audio-quality 0 \"\(sourceURLString)\""
        )
    }
}

private struct ProcessCommand {
    let executableURL: URL
    var currentDirectoryURL: URL? = nil
    var environment: [String: String]? = nil
    let arguments: [String]

    var rendered: String {
        let head = executableURL.path
        let joined = arguments.map { arg in
            if arg.contains(" ") {
                return "\"\(arg)\""
            }
            return arg
        }.joined(separator: " ")
        return "\(head) \(joined)"
    }
}

private struct ProcessRunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

nonisolated private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutText = ""
    private var stderrText = ""

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

private enum ProcessRunnerError: Error {
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
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
            return "exit=\(exitCode)"
        }
    }
}

private extension AudioExtractService {
    func runProcess(command: ProcessCommand, onLog: @escaping (String) -> Void) async throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.currentDirectoryURL = command.currentDirectoryURL
        process.environment = command.environment
        process.arguments = command.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let buffer = ProcessOutputBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            buffer.appendStdout(text)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onLog(text.trimmingCharacters(in: .newlines))
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            buffer.appendStderr(text)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onLog(text.trimmingCharacters(in: .newlines))
            }
        }

        activeProcess = process
        do {
            try process.run()
        } catch {
            activeProcess = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        defer { activeProcess = nil }

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessRunResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOut.isEmpty {
                    buffer.appendStdout(String(decoding: remainingOut, as: UTF8.self))
                }

                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty {
                    buffer.appendStderr(String(decoding: remainingErr, as: UTF8.self))
                }

                let output = buffer.snapshot()
                let result = ProcessRunResult(
                    stdout: output.stdout,
                    stderr: output.stderr,
                    exitCode: process.terminationStatus
                )
                if process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM {
                    continuation.resume(throwing: AudioExtractServiceError.cancelled)
                    return
                }
                if process.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: ProcessRunnerError.commandFailed(
                        stdout: output.stdout,
                        stderr: output.stderr,
                        exitCode: process.terminationStatus
                    ))
                }
            }
        }
        return result
    }

    func runProcessSync(command: ProcessCommand) throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.currentDirectoryURL = command.currentDirectoryURL
        process.environment = command.environment
        process.arguments = command.arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let result = ProcessRunResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
        if process.terminationStatus != 0 {
            throw ProcessRunnerError.commandFailed(stdout: out, stderr: err, exitCode: process.terminationStatus)
        }
        return result
    }
}
