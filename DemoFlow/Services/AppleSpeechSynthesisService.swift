import AVFoundation
import Foundation

final class AppleSpeechSynthesisService: AppleTTSService {
    func availableVoices(for language: String?) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                guard let language else { return true }
                return voice.language == language || voice.language.hasPrefix(language.split(separator: "-").first.map(String.init) ?? language)
            }
            .sorted {
                if $0.quality != $1.quality {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func synthesize(
        text: String,
        voiceIdentifier: String?,
        rate: Double,
        outputURL: URL
    ) async throws -> URL {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw SubDubError.emptyText
        }

        let utterance = AVSpeechUtterance(string: normalizedText)
        if let voiceIdentifier, !voiceIdentifier.isEmpty {
            guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
                throw SubDubError.speechVoiceMissing
            }
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(max(rate, 0.5), 2.0))

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let session = SpeechWriteSession(outputURL: outputURL)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                session.start(utterance: utterance, continuation: continuation)
            }
        }, onCancel: {
            Task { @MainActor in
                session.cancel()
            }
        })
    }
}

private final class SpeechWriteSession {
    private let outputURL: URL
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(
        utterance: AVSpeechUtterance,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.continuation = continuation
        synthesizer.write(utterance) { [weak self] buffer in
            self?.receive(buffer)
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(CancellationError()))
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            finish(.failure(SubDubError.speechOutputMissing))
            return
        }

        if pcmBuffer.frameLength == 0 {
            guard audioFile != nil else {
                finish(.failure(SubDubError.speechOutputMissing))
                return
            }
            do {
                try validateOutput()
                finish(.success(outputURL))
            } catch {
                finish(.failure(error))
            }
            return
        }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: pcmBuffer.format.settings
                )
            }
            try audioFile?.write(from: pcmBuffer)
        } catch {
            finish(.failure(error))
        }
    }

    private func validateOutput() throws {
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw SubDubError.speechOutputMissing
        }
        let file = try AVAudioFile(forReading: outputURL)
        guard file.length > 0 else {
            throw SubDubError.speechOutputMissing
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        if case .failure = result {
            try? FileManager.default.removeItem(at: outputURL)
        }
        continuation?.resume(with: result)
    }
}
