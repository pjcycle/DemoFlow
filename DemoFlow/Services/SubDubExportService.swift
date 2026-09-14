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

    func extractAudioForTranscription(from videoURL: URL, outputURL: URL) async throws {
        let tools = try binaryService.ensureReady()
        try prepareOutput(outputURL)
        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", videoURL.path,
                "-map", "0:a:0",
                "-vn", "-sn", "-dn",
                "-ac", "1", "-ar", "16000",
                "-af", "aresample=async=1:first_pts=0",
                "-avoid_negative_ts", "make_zero",
                "-c:a", "pcm_s16le",
                "-f", "wav",
                outputURL.path
            ],
            expectedDurationSeconds: nil
        )
        do {
            _ = try await runner.run(command: command)
            try validateTranscriptionAudio(outputURL)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
    }

    func extractWaveformSamples(
        from videoURL: URL,
        outputURL: URL,
        sampleCount: Int = 512
    ) async throws -> [Double] {
        let asset = AVAssetAsyncLoaders.makeURLAsset(videoURL)
        guard try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio) != nil else {
            throw SubDubError.audioValidationFailed
        }

        let tools = try binaryService.ensureReady()
        try prepareOutput(outputURL)
        defer { try? fileManager.removeItem(at: outputURL) }

        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", videoURL.path,
                "-map", "0:a:0",
                "-vn", "-sn", "-dn",
                "-ac", "1", "-ar", "1000",
                "-f", "s16le", outputURL.path
            ],
            expectedDurationSeconds: nil
        )
        do {
            _ = try await runner.run(command: command)
            let waveformService = SubDubWaveformService(sampleCount: sampleCount)
            return try await waveformService.samples(fromRawPCM: outputURL)
        } catch {
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
    }

    func makeDubbingMixdown(
        sourceVideoURL: URL?,
        sourceAudioURL: URL?,
        segments: [VideoDubbingSegment],
        duration: Double,
        outputURL: URL
    ) async throws {
        try await makeDubbingMixdownWithFFmpeg(
            sourceVideoURL: sourceVideoURL,
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
        style: SubtitleStylePreset = .standard,
        themeColor: SubtitleThemeColor = .white,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let videoSize = try await subtitleCanvasSize(from: videoURL)
        let intermediateURL = sessionDirectory.appendingPathComponent(
            "subtitle_burned_video.mp4"
        )
        do {
            // Burn the current subtitle document first. The second pass only changes audio,
            // so the final video always keeps the already-rendered captions.
            try await burnSubtitles(
                videoURL: videoURL,
                cues: cues.map(SubtitleTimelineCue.init(cue:)),
                outputURL: intermediateURL,
                duration: duration,
                sessionDirectory: sessionDirectory,
                videoSize: videoSize,
                style: style,
                themeColor: themeColor,
                progress: progress
            )
            try await replaceAudio(
                videoURL: intermediateURL,
                audioURL: audioURL,
                outputURL: outputURL,
                duration: duration,
                progress: progress
            )
        } catch {
            try? fileManager.removeItem(at: intermediateURL)
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
        try? fileManager.removeItem(at: intermediateURL)
    }

    func fitAudioToDuration(
        sourceURL: URL,
        targetDuration: Double,
        outputURL: URL
    ) async throws {
        guard targetDuration >= 0.1 else {
            throw SubDubError.audioReplacementTiming("字幕区间太短")
        }
        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await asset.load(.duration).seconds
        guard sourceDuration > 0 else {
            throw SubDubError.speechOutputMissing
        }

        let speed = sourceDuration / targetDuration
        guard speed <= 2.0 else {
            throw SubDubError.audioReplacementTiming(
                String(format: "%.2f 秒语音无法放入 %.2f 秒区间", sourceDuration, targetDuration)
            )
        }

        let tools = try binaryService.ensureReady()
        try prepareOutput(outputURL)
        var filters: [String] = []
        if speed > 1.001 {
            filters.append("atempo=\(ffmpegSeconds(speed))")
        }
        filters.append("apad=whole_dur=\(ffmpegSeconds(targetDuration))")
        filters.append("atrim=duration=\(ffmpegSeconds(targetDuration))")

        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", sourceURL.path,
                "-af", filters.joined(separator: ","),
                "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le",
                outputURL.path
            ],
            expectedDurationSeconds: targetDuration
        )
        do {
            _ = try await runner.run(command: command)
            try await validateAudio(outputURL)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    func makeAudioReplacementMixdown(
        segments: [AudioReplacementSegment],
        duration: Double,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let orderedSegments = segments
            .filter { $0.endTime - $0.startTime >= 0.05 }
            .sorted { $0.startTime < $1.startTime }
        guard duration > 0, !orderedSegments.isEmpty else {
            throw SubDubError.audioReplacementMixFailed(
                L10n.tr("subdub.audio_replacement.timeline_empty")
            )
        }

        let tools = try binaryService.ensureReady()
        var arguments = ["-hide_banner", "-loglevel", "error", "-y"]
        for segment in orderedSegments {
            arguments += ["-i", segment.audioURL.path]
        }

        let durationText = ffmpegSeconds(duration)
        var filters: [String] = []
        var labels: [String] = []
        for (index, segment) in orderedSegments.enumerated() {
            let delay = max(0, Int((segment.startTime * 1_000).rounded()))
            let label = "speech\(index)"
            filters.append(
                "[\(index):a]aresample=44100,aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo,adelay=\(delay)|\(delay),apad=whole_dur=\(durationText),atrim=duration=\(durationText)[\(label)]"
            )
            labels.append("[\(label)]")
        }
        filters.append(
            "\(labels.joined())amix=inputs=\(labels.count):duration=longest:normalize=0,aresample=44100,aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo,atrim=duration=\(durationText)[outa]"
        )
        arguments += [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[outa]", "-vn", "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart", outputURL.path
        ]

        try prepareOutput(outputURL)
        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: arguments,
            expectedDurationSeconds: duration
        )
        do {
            _ = try await runner.run(command: command, onProgress: progress)
            try await validateAudio(outputURL)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw SubDubError.audioReplacementMixFailed(error.localizedDescription)
        }
    }

    func burnSubtitles(
        videoURL: URL,
        cues: [SubtitleTimelineCue],
        outputURL: URL,
        duration: Double,
        sessionDirectory: URL,
        videoSize: CGSize,
        style: SubtitleStylePreset,
        themeColor: SubtitleThemeColor = .white,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let tools = try binaryService.ensureReady()
        let subtitleURL = sessionDirectory.appendingPathComponent("captions.ass")
        try SubtitleASSWriter.write(
            cues: cues.map(\.subtitleCue),
            to: subtitleURL,
            style: style,
            themeColor: themeColor,
            videoSize: videoSize
        )
        try prepareOutput(outputURL)
        let filter = "subtitles=\(escapeFilterPath(subtitleURL.path)):charenc=UTF-8"
        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: [
                "-y", "-i", videoURL.path,
                "-map", "0:v:0", "-map", "0:a?",
                "-vf", filter,
                "-c:v", "libx264", "-preset", "medium", "-crf", "18",
                "-c:a", "copy",
                "-t", formatDuration(duration),
                "-movflags", "+faststart", outputURL.path
            ],
            expectedDurationSeconds: duration
        )
        do {
            _ = try await runner.run(command: command, onProgress: progress)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw SubDubError.serviceFailed(error.localizedDescription)
        }
        try await validateMedia(outputURL, requireVideo: true)
    }

    private func subtitleCanvasSize(from videoURL: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await AVAssetAsyncLoaders.firstTrack(
            in: asset,
            mediaType: .video
        ) else {
            throw SubDubError.videoValidationFailed
        }
        let size = try await AVAssetAsyncLoaders.orientedSize(of: videoTrack)
        guard size.width > 0, size.height > 0 else {
            throw SubDubError.videoValidationFailed
        }
        return size
    }

    func validateAudio(_ url: URL) async throws {
        try await validateMedia(url, requireVideo: false)
    }

    func validateTranscriptionAudio(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 44 else {
            throw SubDubError.audioValidationFailed
        }

        // Whisper receives a local PCM WAV produced by FFmpeg. Do not ask
        // AVFoundation to rediscover the source video's audio track here;
        // some downloaded MP4 containers expose that track inconsistently.
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        guard audioFile.length > 0,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            throw SubDubError.audioValidationFailed
        }
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
        sourceVideoURL: URL?,
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
        let sourceInputURL = sourceAudioURL ?? sourceVideoURL
        let sourceInputIndex: Int?
        if let sourceInputURL {
            sourceInputIndex = 0
            arguments += ["-i", sourceInputURL.path]
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
    static func write(
        cues: [SubtitleCue],
        to url: URL,
        style: SubtitleStylePreset = .standard,
        themeColor: SubtitleThemeColor = .white,
        videoSize: CGSize = CGSize(width: 1920, height: 1080)
    ) throws {
        let width = max(1, Int(videoSize.width.rounded()))
        let height = max(1, Int(videoSize.height.rounded()))
        let fontSize = style.assFontSize(forVideoHeight: CGFloat(height))
        let marginV = style.assMarginV(forVideoHeight: CGFloat(height))
        let sideMargin = max(20, Int((Double(width) * 0.02).rounded()))
        let backgroundColour = assBackgroundColour(opacity: style.backgroundOpacity)
        let bold = style.isBold ? -1 : 0

        var lines = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "PlayResX: \(width)",
            "PlayResY: \(height)",
            "WrapStyle: 2",
            "ScaledBorderAndShadow: yes",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: Default,\(style.fontName),\(fontSize),\(themeColor.assColour),\(themeColor.assColour),&H00000000,\(backgroundColour),\(bold),0,0,0,100,100,0,0,\(style.assBorderStyle),\(style.assOutlineWidth),0,2,\(sideMargin),\(sideMargin),\(marginV),1",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
        ]
        lines.append(contentsOf: cues.map { cue in
            "Dialogue: 0,\(time(cue.start.seconds)),\(time(cue.end.seconds)),Default,,0,0,0,,\(sanitize(cue.text))"
        })
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func assBackgroundColour(opacity: Double) -> String {
        let clampedOpacity = min(max(opacity, 0), 1)
        let alpha = Int(((1 - clampedOpacity) * 255).rounded())
        return String(format: "&H%02X000000", alpha)
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
