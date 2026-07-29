import Foundation

struct WhisperToolPaths {
    let executableURL: URL
    let modelURL: URL
}

struct WhisperBinaryService {
    private let fileManager = FileManager.default

    func ensureReady() throws -> WhisperToolPaths {
        guard let executableURL = resolveExecutable() else {
            throw SubDubError.whisperDependencyMissing
        }
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw SubDubError.whisperDependencyMissing
        }
        guard let modelURL = resolveModel(), fileManager.fileExists(atPath: modelURL.path) else {
            throw SubDubError.whisperModelMissing
        }
        return WhisperToolPaths(executableURL: executableURL, modelURL: modelURL)
    }

    private func resolveExecutable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["DEMOFLOW_WHISPER_CLI"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        var candidates: [URL] = []
        if let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true) as URL? {
            candidates.append(helpers.appendingPathComponent("whisper-cli"))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("whisper-cli"))
            candidates.append(
                resourceURL
                    .appendingPathComponent("ThirdParty", isDirectory: true)
                    .appendingPathComponent("whisper", isDirectory: true)
                    .appendingPathComponent("arm64", isDirectory: true)
                    .appendingPathComponent("whisper-cli")
            )
        }
        if let direct = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) {
            candidates.append(direct)
        }
        return firstExisting(candidates, executableOnly: true)
    }

    private func resolveModel() -> URL? {
        if let override = ProcessInfo.processInfo.environment["DEMOFLOW_WHISPER_MODEL"],
           fileManager.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates += [
                resourceURL.appendingPathComponent("ggml-base.bin"),
                resourceURL
                    .appendingPathComponent("Models", isDirectory: true)
                    .appendingPathComponent("ggml-base.bin"),
                resourceURL
                    .appendingPathComponent("ThirdParty", isDirectory: true)
                    .appendingPathComponent("whisper", isDirectory: true)
                    .appendingPathComponent("models", isDirectory: true)
                    .appendingPathComponent("ggml-base.bin")
            ]
        }
        if let direct = Bundle.main.url(forResource: "ggml-base", withExtension: "bin") {
            candidates.append(direct)
        }
        return firstExisting(candidates, executableOnly: false)
    }

    private func firstExisting(_ candidates: [URL], executableOnly: Bool) -> URL? {
        var visited = Set<String>()
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            guard visited.insert(resolved.path).inserted,
                  fileManager.fileExists(atPath: resolved.path) else { continue }
            if !executableOnly || fileManager.isExecutableFile(atPath: resolved.path) {
                return resolved
            }
        }
        return nil
    }
}

nonisolated final class WhisperRunner {
    func run(
        executableURL: URL,
        modelURL: URL,
        audioURL: URL,
        outputBaseURL: URL
    ) async throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-oj",
            "-of", outputBaseURL.path,
            "-l", "auto",
            // CPU mode is more reliable for a sandboxed helper across Macs;
            // Metal allocation can fail even when the app itself has a GPU.
            "-ng"
        ]

        let stderr = Pipe()
        process.standardOutput = FileHandle.standardError
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    let errorText = String(
                        decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: SubDubError.transcriptionFailed(errorText))
                        return
                    }

                    let jsonURL = outputBaseURL.appendingPathExtension("json")
                    guard let data = try? Data(contentsOf: jsonURL), !data.isEmpty else {
                        continuation.resume(throwing: SubDubError.transcriptionOutputMissing)
                        return
                    }
                    continuation.resume(returning: data)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SubDubError.transcriptionFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

@MainActor
struct WhisperTranscriptionService {
    private let binaryService = WhisperBinaryService()
    private let runner = WhisperRunner()

    func transcribe(
        audioURL: URL,
        sessionDirectory: URL
    ) async throws -> [SubtitleTimelineCue] {
        let tools = try binaryService.ensureReady()
        let outputBase = sessionDirectory.appendingPathComponent("WhisperTranscription")
        try? FileManager.default.removeItem(at: outputBase.appendingPathExtension("json"))
        let data = try await runner.run(
            executableURL: tools.executableURL,
            modelURL: tools.modelURL,
            audioURL: audioURL,
            outputBaseURL: outputBase
        )
        let result = try WhisperJSONParser.parse(data)
        return ChineseSimplifiedNormalizer.normalize(result)
    }
}

@MainActor
private enum WhisperJSONParser {
    struct Result {
        let language: String?
        let cues: [SubtitleTimelineCue]
    }

    static func parse(_ data: Data) throws -> Result {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubDubError.transcriptionInvalidJSON
        }

        let entries = (object["transcription"] as? [[String: Any]])
            ?? (object["segments"] as? [[String: Any]])
            ?? []
        let cues = entries.compactMap(parseEntry(_:))
        guard !cues.isEmpty else {
            throw SubDubError.transcriptionEmpty
        }
        let language = (object["result"] as? [String: Any])?["language"] as? String
            ?? object["language"] as? String
        return Result(
            language: language,
            cues: cues.sorted { $0.startTime < $1.startTime }
        )
    }

    private static func parseEntry(_ entry: [String: Any]) -> SubtitleTimelineCue? {
        let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }

        let timestamps = entry["timestamps"] as? [String: Any]
        let offsets = entry["offsets"] as? [String: Any]
        let start = parseTime(
            timestamps?["from"] ?? entry["start"] ?? offsets?["from"]
        )
        let end = parseTime(
            timestamps?["to"] ?? entry["end"] ?? offsets?["to"]
        )
        guard let start, let end, end > start else { return nil }
        return SubtitleTimelineCue(startTime: start, endTime: end, text: text)
    }

    private static func parseTime(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return raw > 10_000 ? raw / 1_000.0 : raw
        }
        guard let string = value as? String else { return nil }
        let normalized = string.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        if parts.count >= 2 {
            let seconds = Double(parts.last ?? "") ?? 0
            let minutes = Double(parts[parts.count - 2]) ?? 0
            let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
            return hours * 3600 + minutes * 60 + seconds
        }
        return Double(normalized)
    }
}

private enum ChineseSimplifiedNormalizer {
    static func normalize(_ result: WhisperJSONParser.Result) -> [SubtitleTimelineCue] {
        guard result.language?.lowercased().hasPrefix("zh") == true else {
            return result.cues
        }

        return result.cues.map { cue in
            var normalized = cue
            normalized.text = cue.text.applyingTransform(
                StringTransform(rawValue: "Traditional-Simplified"),
                reverse: false
            ) ?? cue.text
            return normalized
        }
    }
}
