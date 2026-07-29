import AVFoundation
import Combine
import Foundation

@MainActor
final class SubDubTimelineSession: ObservableObject {
    @Published private(set) var videoURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var sourceAudioURL: URL?
    @Published private(set) var sourceWaveformSamples: [Double] = []
    @Published private(set) var document: SubtitleTimelineDocument?
    @Published private(set) var sessionDirectory: URL?

    var hasProject: Bool { videoURL != nil && sourceDuration > 0 }

    func configureProject(
        videoURL: URL,
        duration: Double,
        sessionDirectory: URL
    ) throws {
        guard duration > 0 else {
            throw SubDubError.videoValidationFailed
        }
        self.videoURL = videoURL
        sourceDuration = duration
        sourceAudioURL = nil
        sourceWaveformSamples = []
        self.sessionDirectory = sessionDirectory
        try updateDocument(SubtitleTimelineDocument(sourceDuration: duration))
    }

    func updateSourceAudio(url: URL, waveformSamples: [Double]) {
        sourceAudioURL = url
        sourceWaveformSamples = waveformSamples
    }

    func updateDocument(_ document: SubtitleTimelineDocument) throws {
        guard document.sourceDuration > 0 else {
            throw SubDubError.subtitleBurnValidationFailed(
                L10n.tr("subdub.error.subtitle_out_of_range")
            )
        }
        if let sessionDirectory {
            let url = sessionDirectory.appendingPathComponent("SubtitleTimeline.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
        }
        self.document = document
    }

    func clearProject() {
        videoURL = nil
        sourceDuration = 0
        sourceAudioURL = nil
        sourceWaveformSamples = []
        document = nil
        sessionDirectory = nil
    }
}

struct SubDubWaveformService {
    let sampleCount: Int

    init(sampleCount: Int = 512) {
        self.sampleCount = max(sampleCount, 32)
    }

    func samples(from url: URL) async throws -> [Double] {
        let count = sampleCount
        return try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            let totalFrames = file.length
            guard totalFrames > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: 4096
                  ) else {
                return []
            }

            let channelCount = max(Int(file.processingFormat.channelCount), 1)
            var samples = Array(repeating: 0.0, count: count)
            var frameOffset: AVAudioFramePosition = 0

            while frameOffset < totalFrames {
                let remainingFrames = totalFrames - frameOffset
                let framesToRead = AVAudioFrameCount(
                    min(AVAudioFramePosition(buffer.frameCapacity), remainingFrames)
                )
                try file.read(into: buffer, frameCount: framesToRead)
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { break }

                if let channelData = buffer.floatChannelData {
                    for frame in 0..<frameLength {
                        let absoluteFrame = frameOffset + AVAudioFramePosition(frame)
                        let bucket = min(
                            count - 1,
                            Int(Double(absoluteFrame) / Double(totalFrames) * Double(count))
                        )
                        var power = 0.0
                        for channel in 0..<channelCount {
                            let value = Double(channelData[channel][frame])
                            power += value * value
                        }
                        samples[bucket] = max(
                            samples[bucket],
                            sqrt(power / Double(channelCount))
                        )
                    }
                }
                frameOffset += AVAudioFramePosition(frameLength)
            }

            let peak = samples.max() ?? 0
            guard peak > 0 else { return samples }
            return samples.map { min(max($0 / peak, 0), 1) }
        }.value
    }
}
