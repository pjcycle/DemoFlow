import AVFoundation
import Foundation

struct SubDubExportService {
    private let binaryService = FFmpegBinaryService()
    private let runner = FFmpegRunner()
    private let fileManager = FileManager.default

    func extractAudioTrack(from videoURL: URL, outputURL: URL) async throws -> Bool {
        let asset = AVAssetAsyncLoaders.makeURLAsset(videoURL)
        guard try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio) != nil else {
            return false
        }

        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: outputURL)

        do {
            let tools = try binaryService.ensureReady()
            let command = FFmpegCommand(
                executableURL: tools.ffmpegURL,
                arguments: [
                    "-hide_banner", "-loglevel", "error", "-y",
                    "-i", videoURL.path,
                    "-vn", "-ac", "2", "-ar", "44100",
                    "-c:a", "aac", "-b:a", "128k", outputURL.path
                ],
                expectedDurationSeconds: nil
            )
            _ = try await runner.run(command: command)
            try await validateAudio(outputURL)
            return true
        } catch {
            try? fileManager.removeItem(at: outputURL)
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SubDubError.audioValidationFailed
        }
        try await AVAssetAsyncLoaders.export(exporter, outputURL: outputURL, outputFileType: .m4a)
        try await validateAudio(outputURL)
        return true
    }

    func makeDubbingMixdown(
        sourceAudioURL: URL?,
        segments: [VideoDubbingSegment],
        duration: Double,
        outputURL: URL
    ) async throws {
        try await makeDubbingMixdownWithFFmpeg(
            sourceAudioURL: sourceAudioURL,
            segments: segments,
            duration: duration,
            outputURL: outputURL
        )
        try await validateAudio(outputURL)
    }

    func replaceAudio(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        duration: Double,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let tools = try binaryService.ensureReady()
        try prepareOutput(outputURL)
        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-y", "-i", videoURL.path, "-i", audioURL.path,
                "-map", "0:v:0", "-map", "1:a:0",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "128k",
                "-af", "apad", "-t", formatDuration(duration),
                "-movflags", "+faststart", outputURL.path
            ],
            expectedDurationSeconds: duration
        )
        do {
            _ = try await runner.run(command: command, onProgress: progress)
        } catch {
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
        try await validateMedia(outputURL, requireVideo: true)
    }

    func burnSubtitlesAndReplaceAudio(
        videoURL: URL,
        audioURL: URL,
        cues: [SubtitleCue],
        outputURL: URL,
        duration: Double,
        sessionDirectory: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let tools = try binaryService.ensureReady()
        let subtitleURL = sessionDirectory.appendingPathComponent("captions.ass")
        try SubtitleASSWriter.write(cues: cues, to: subtitleURL)
        try prepareOutput(outputURL)
        let filter = "subtitles=\(escapeFilterPath(subtitleURL.path))"
        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-y", "-i", videoURL.path, "-i", audioURL.path,
                "-map", "0:v:0", "-map", "1:a:0",
                "-vf", filter, "-c:v", "libx264", "-preset", "medium", "-crf", "18",
                "-c:a", "aac", "-b:a", "128k", "-af", "apad",
                "-t", formatDuration(duration), "-movflags", "+faststart", outputURL.path
            ],
            expectedDurationSeconds: duration
        )
        do {
            _ = try await runner.run(command: command, onProgress: progress)
        } catch {
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
        try await validateMedia(outputURL, requireVideo: true)
    }

    func validateAudio(_ url: URL) async throws {
        try await validateMedia(url, requireVideo: false)
    }

    func validateVideo(_ url: URL) async throws -> Double {
        try await validateMedia(url, requireVideo: true)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return max(duration.seconds, 0)
    }

    private func validateMedia(_ url: URL, requireVideo: Bool) async throws {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw requireVideo ? SubDubError.videoValidationFailed : SubDubError.audioValidationFailed
        }

        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        guard let duration, duration.seconds > 0 else {
            throw requireVideo ? SubDubError.videoValidationFailed : SubDubError.audioValidationFailed
        }
        if requireVideo {
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            guard tracks?.isEmpty == false else { throw SubDubError.videoValidationFailed }
        } else {
            let tracks = try? await asset.loadTracks(withMediaType: .audio)
            guard tracks?.isEmpty == false else { throw SubDubError.audioValidationFailed }
        }
    }

    private func prepareOutput(_ url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func makeDubbingMixdownWithFFmpeg(
        sourceAudioURL: URL?,
        segments: [VideoDubbingSegment],
        duration: Double,
        outputURL: URL
    ) async throws {
        let clampedDuration = max(duration, 0)
        let orderedSegments = segments
            .filter { $0.duration >= 0.05 }
            .sorted { $0.timelineStart < $1.timelineStart }
        guard clampedDuration > 0, !orderedSegments.isEmpty else {
            throw SubDubError.audioValidationFailed
        }

        let tools = try binaryService.ensureReady()
        var arguments = ["-hide_banner", "-loglevel", "error", "-y"]
        let sourceInputIndex: Int?
        if let sourceAudioURL {
            sourceInputIndex = 0
            arguments += ["-i", sourceAudioURL.path]
        } else {
            sourceInputIndex = nil
        }
        for segment in orderedSegments {
            arguments += ["-i", segment.audioURL.path]
        }

        let durationText = ffmpegSeconds(clampedDuration)
        var filters: [String] = []
        if sourceInputIndex != nil {
            filters.append(
                "[0:a]aresample=44100,aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo,apad,atrim=duration=\(durationText)[base]"
            )
        } else {
            filters.append("anullsrc=r=44100:cl=stereo,atrim=duration=\(durationText)[base]")
        }

        var baseLabel = "base"
        var takeLabels: [String] = []
        for (index, segment) in orderedSegments.enumerated() {
            let start = max(0, min(segment.timelineStart, clampedDuration))
            let end = max(start, min(segment.timelineEnd, clampedDuration))
            let startText = ffmpegSeconds(start)
            let endText = ffmpegSeconds(end)
            let mutedLabel = "baseMuted\(index)"
            filters.append(
                "[\(baseLabel)]volume=enable=between(t\\,\(startText)\\,\(endText)):volume=0[\(mutedLabel)]"
            )
            baseLabel = mutedLabel

            let inputIndex = (sourceInputIndex == nil ? 0 : 1) + index
            let delayMilliseconds = max(0, Int((start * 1_000).rounded()))
            let audioStart = max(0, segment.audioStartTime)
            let audioEnd = audioStart + max(0.05, end - start)
            let takeLabel = "take\(index)"
            filters.append(
                "[\(inputIndex):a]aresample=44100,aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo,atrim=start=\(ffmpegSeconds(audioStart)):end=\(ffmpegSeconds(audioEnd)),asetpts=PTS-STARTPTS,adelay=\(delayMilliseconds)|\(delayMilliseconds),apad=whole_dur=\(durationText),atrim=duration=\(durationText)[\(takeLabel)]"
            )
            takeLabels.append(takeLabel)
        }

        let mixInputs = (["[\(baseLabel)]"] + takeLabels.map { "[\($0)]" }).joined()
        filters.append(
            "\(mixInputs)amix=inputs=\(takeLabels.count + 1):duration=longest:normalize=0,aresample=44100,aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo,atrim=duration=\(durationText)[outa]"
        )

        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: outputURL)
        arguments += [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[outa]",
            "-vn", "-c:a", "aac", "-b:a", "128k",
            outputURL.path
        ]

        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: arguments,
            expectedDurationSeconds: clampedDuration
        )
        do {
            _ = try await runner.run(command: command)
        } catch {
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
    }

    private func formatDuration(_ value: Double) -> String {
        String(format: "%.3f", max(value, 0.1))
    }

    private func ffmpegSeconds(_ value: Double) -> String {
        String(format: "%.3f", max(value, 0))
    }

    private func escapeFilterPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

private enum SubtitleASSWriter {
    static func write(cues: [SubtitleCue], to url: URL) throws {
        var lines = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "PlayResX: 1920",
            "PlayResY: 1080",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: Default,Arial,26,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,3,1,0,2,36,36,36,1",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
        ]
        lines.append(contentsOf: cues.map { cue in
            "Dialogue: 0,\(time(cue.start.seconds)),\(time(cue.end.seconds)),Default,,0,0,0,,\(sanitize(cue.text))"
        })
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func time(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 100).rounded()))
        let centiseconds = total % 100
        let totalSeconds = total / 100
        let second = totalSeconds % 60
        let minute = (totalSeconds / 60) % 60
        let hour = totalSeconds / 3600
        return String(format: "%d:%02d:%02d.%02d", hour, minute, second, centiseconds)
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\N")
    }
}
