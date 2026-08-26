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
            "-ng",
            // Cap each whisper segment at ~60 characters so long passages get
            // split into more natural-sized chunks before punctuation-aware
            // post-processing below.
            "-ml", "60"
        ]

        let stderr = Pipe()
        let outputCapture = WhisperProcessOutputCapture()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputCapture.append(String(decoding: data, as: UTF8.self))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    stderr.fileHandleForReading.readabilityHandler = nil
                    let remaining = stderr.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        outputCapture.append(String(decoding: remaining, as: UTF8.self))
                    }
                    let errorText = String(
                        outputCapture.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    guard process.terminationStatus == 0 else {
                        let reason = errorText.isEmpty
                            ? "Whisper exited with status \(process.terminationStatus)."
                            : errorText
                        continuation.resume(throwing: SubDubError.transcriptionFailed(reason))
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

nonisolated private final class WhisperProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private let maxCharacters = 32_000

    func append(_ text: String) {
        lock.withLock {
            value.append(text)
            if value.count > maxCharacters {
                value = String(value.suffix(maxCharacters))
            }
        }
    }

    func text() -> String {
        lock.withLock { value }
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
        let outputBase = sessionDirectory.appendingPathComponent(
            "WhisperTranscription-\(UUID().uuidString)"
        )
        let data = try await runner.run(
            executableURL: tools.executableURL,
            modelURL: tools.modelURL,
            audioURL: audioURL,
            outputBaseURL: outputBase
        )
        defer {
            try? FileManager.default.removeItem(at: outputBase.appendingPathExtension("json"))
        }
        let result = try WhisperJSONParser.parse(data)
        let normalized = ChineseSimplifiedNormalizer.normalize(result)
        return SubtitlePostProcessor.splitByPunctuation(normalized)
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
            // whisper.cpp's `offsets.from/to` are always emitted in
            // milliseconds, so always normalize to seconds regardless of
            // magnitude. The previous 10_000 threshold silently mangled any
            // short clip whose offset sat below 10s.
            return number.doubleValue / 1_000.0
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

@MainActor
enum SubtitlePostProcessor {
    private static let strongPunctuation: Set<Character> = [
        ".", "?", "!", "。", "？", "！"
    ]
    private static let weakPunctuation: Set<Character> = [
        ",", ";", ":", "，", "；", "："
    ]
    private static let maxCharactersPerCue = 50
    private static let minCharactersForStrongCut = 8
    private static let minCharactersForWeakCut = 20
    private static let minPieceDuration: Double = 1.0

    /// Splits each cue into multiple shorter cues at natural punctuation
    /// boundaries so subtitles read like sentences instead of long
    /// whisper.cpp default segments. Time is allocated proportionally to the
    /// character count within the original cue.
    static func splitByPunctuation(_ cues: [SubtitleTimelineCue]) -> [SubtitleTimelineCue] {
        cues.flatMap { split(cue: $0) }
    }

    private static func split(cue: SubtitleTimelineCue) -> [SubtitleTimelineCue] {
        let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count > maxCharactersPerCue else {
            return trimmed.isEmpty ? [] : [cue]
        }

        let chars = Array(trimmed)
        let totalChars = chars.count
        let totalDuration = cue.endTime - cue.startTime
        guard totalChars > 0, totalDuration > 0 else {
            return [cue]
        }
        let charDuration = totalDuration / Double(totalChars)

        var pieces: [(text: String, charStart: Int)] = []
        var currentChars: [Character] = []
        var currentStart = 0

        for i in 0..<totalChars {
            let c = chars[i]
            currentChars.append(c)
            let isLast = i == totalChars - 1
            let isStrong = strongPunctuation.contains(c)
            let isWeak = weakPunctuation.contains(c)
            let exceedsMax = currentChars.count >= maxCharactersPerCue

            let shouldCut = isLast
                || (isStrong && currentChars.count >= minCharactersForStrongCut)
                || (isWeak && currentChars.count >= minCharactersForWeakCut)
                || exceedsMax

            if shouldCut {
                let pieceText = String(currentChars)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pieceText.isEmpty {
                    pieces.append((pieceText, currentStart))
                }
                currentStart = i + 1
                currentChars = []
            }
        }

        let mergedPieces = mergeShortPieces(
            pieces: pieces,
            charDuration: charDuration,
            cueStartTime: cue.startTime,
            cueEndTime: cue.endTime,
            minPieceDuration: minPieceDuration
        )

        return mergedPieces.map { piece in
            let startOffset = Double(piece.charStart) * charDuration
            let endOffset = Double(piece.charStart + piece.text.count) * charDuration
            return SubtitleTimelineCue(
                startTime: cue.startTime + startOffset,
                endTime: min(cue.startTime + endOffset, cue.endTime),
                text: piece.text
            )
        }
    }

    /// Merges any piece whose duration is shorter than `minPieceDuration`
    /// into its predecessor so every emitted cue lasts at least the
    /// minimum. Whitespace between merged pieces is preserved.
    private static func mergeShortPieces(
        pieces: [(text: String, charStart: Int)],
        charDuration: Double,
        cueStartTime: Double,
        cueEndTime: Double,
        minPieceDuration: Double
    ) -> [(text: String, charStart: Int)] {
        guard !pieces.isEmpty else { return pieces }
        var merged: [(text: String, charStart: Int)] = []
        for piece in pieces {
            if let last = merged.indices.last,
               let lastPiece = merged.indices.last.map({ merged[$0] }),
               pieceDuration(charStart: lastPiece.charStart,
                             textLength: lastPiece.text.count,
                             charDuration: charDuration) < minPieceDuration {
                merged[last] = (
                    text: lastPiece.text + " " + piece.text,
                    charStart: lastPiece.charStart
                )
            } else if pieceDuration(charStart: piece.charStart,
                                    textLength: piece.text.count,
                                    charDuration: charDuration) < minPieceDuration,
                      !merged.isEmpty {
                let lastIdx = merged.count - 1
                merged[lastIdx] = (
                    text: merged[lastIdx].text + " " + piece.text,
                    charStart: merged[lastIdx].charStart
                )
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    private static func pieceDuration(
        charStart: Int,
        textLength: Int,
        charDuration: Double
    ) -> Double {
        Double(textLength) * charDuration
    }
}
