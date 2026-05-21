//
//  VideoCuttingFFmpegExportEngine.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/12.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

final class VideoCuttingFFmpegExportEngine {
    private let binaryService = FFmpegBinaryService()
    private let runner = FFmpegRunner()
    private let fileManager = FileManager.default

    func ensureToolsReady() throws {
        _ = try binaryService.ensureReady()
    }

    func export(
        project: VideoCuttingFFmpegProject,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let tools = try binaryService.ensureReady()
        let context = try await makeExportContext(project: project)

        try removeFileIfExists(at: project.outputURL)
        if let singlePassCommand = try buildSinglePassCommand(
            tools: tools,
            context: context,
            outputURL: project.outputURL
        ) {
            _ = try await runner.run(command: singlePassCommand, onProgress: onProgress)
        } else {
            try await exportUsingSegmentedConcat(
                tools: tools,
                context: context,
                outputURL: project.outputURL,
                onProgress: onProgress
            )
        }

        guard FileManager.default.fileExists(atPath: project.outputURL.path) else {
            throw FFmpegComposeError.outputMissing
        }
        return project.outputURL
    }
}

private extension VideoCuttingFFmpegExportEngine {
    struct ExportContext {
        let sourceURL: URL
        let sourceDuration: Double
        let expectedOutputDuration: Double
        let keepRanges: [CMTimeRange]
        let cropPixels: CGRect
        let isFullCrop: Bool
        let isFullKeep: Bool
        let hasAudioTrack: Bool
        let audioFilterChain: String?
        let performanceProfile: VideoCuttingFFmpegProject.PerformanceProfile
    }

    struct SegmentJob {
        let index: Int
        let startSeconds: Double
        let durationSeconds: Double
        let outputURL: URL
    }

    struct SegmentWorkspace {
        let rootURL: URL
        let segmentsDirectoryURL: URL
        let concatListURL: URL
    }

    func makeExportContext(project: VideoCuttingFFmpegProject) async throws -> ExportContext {
        let asset = AVAssetAsyncLoaders.makeURLAsset(project.sourceURL)
        guard let videoTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else {
            throw FFmpegComposeError.missingVideoTrack
        }
        let duration = max(0.001, try await AVAssetAsyncLoaders.duration(of: asset).seconds)
        let keepRanges = normalizeKeepRanges(project.keepRanges, sourceDuration: duration)
        guard !keepRanges.isEmpty else {
            throw FFmpegComposeError.emptyKeepRanges
        }

        let orientedSize = try await AVAssetAsyncLoaders.orientedSize(of: videoTrack)
        guard orientedSize.width > 1, orientedSize.height > 1 else {
            throw FFmpegComposeError.invalidRenderSize
        }

        let cropPixels = cropRectPixels(
            normalized: VideoCropGeometry.clampNormalizedRect(project.cropRectNormalized.cgRect),
            orientedSize: orientedSize
        )
        guard cropPixels.width > 1, cropPixels.height > 1 else {
            throw FFmpegComposeError.invalidCropRect
        }

        let fullCrop = isFullCrop(cropPixels, orientedSize: orientedSize)
        let fullKeep = isFullKeep(keepRanges, duration: duration)
        let hasAudioTrack: Bool
        if project.hasAudioTrack {
            hasAudioTrack = (try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio)) != nil
        } else {
            hasAudioTrack = false
        }
        let audioFilter = hasAudioTrack ? buildAudioFilterChain(config: project.audioProcessingConfig) : nil
        let expectedOutputDuration = keepRanges.reduce(0) { partial, range in
            partial + max(0, range.duration.seconds)
        }
        return ExportContext(
            sourceURL: project.sourceURL,
            sourceDuration: duration,
            expectedOutputDuration: expectedOutputDuration,
            keepRanges: keepRanges,
            cropPixels: cropPixels,
            isFullCrop: fullCrop,
            isFullKeep: fullKeep,
            hasAudioTrack: hasAudioTrack,
            audioFilterChain: audioFilter,
            performanceProfile: project.performanceProfile
        )
    }

    func buildSinglePassCommand(
        tools: FFmpegToolPaths,
        context: ExportContext,
        outputURL: URL
    ) throws -> FFmpegCommand? {
        let shouldFastCopy = context.isFullKeep &&
            context.isFullCrop &&
            context.audioFilterChain == nil

        if shouldFastCopy {
            var args: [String] = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-progress", "pipe:1",
                "-i", context.sourceURL.path,
                "-map", "0:v:0"
            ]
            if context.hasAudioTrack {
                args.append(contentsOf: ["-map", "0:a:0"])
            }
            args.append(contentsOf: ["-c", "copy", "-movflags", "+faststart", outputURL.path])
            return FFmpegCommand(
                executableURL: tools.ffmpegURL,
                arguments: args,
                expectedDurationSeconds: context.sourceDuration
            )
        }

        if context.isFullKeep && context.isFullCrop && !context.hasAudioTrack {
            let videoEncode = videoEncodeSettings(for: context.performanceProfile)
            var args: [String] = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-progress", "pipe:1",
                "-i", context.sourceURL.path,
                "-map", "0:v:0",
                "-c:v", "libx264",
                "-preset", videoEncode.preset,
                "-crf", videoEncode.crf,
                "-pix_fmt", "yuv420p",
                "-an"
            ]
            if let threadLimit = videoEncode.threadLimit {
                args.append(contentsOf: ["-threads", String(threadLimit)])
            }
            args.append(contentsOf: ["-movflags", "+faststart", outputURL.path])
            return FFmpegCommand(
                executableURL: tools.ffmpegURL,
                arguments: args,
                expectedDurationSeconds: context.sourceDuration
            )
        }

        if context.isFullKeep && context.isFullCrop, let audioFilter = context.audioFilterChain {
            let args: [String] = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-progress", "pipe:1",
                "-i", context.sourceURL.path,
                "-map", "0:v:0",
                "-map", "0:a:0",
                "-c:v", "copy",
                "-af", audioFilter,
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart",
                outputURL.path
            ]
            return FFmpegCommand(
                executableURL: tools.ffmpegURL,
                arguments: args,
                expectedDurationSeconds: context.sourceDuration
            )
        }

        return nil
    }

    func exportUsingSegmentedConcat(
        tools: FFmpegToolPaths,
        context: ExportContext,
        outputURL: URL,
        onProgress: ((Double) -> Void)?
    ) async throws {
        let workspace = try prepareSegmentWorkspace()
        defer {
            try? fileManager.removeItem(at: workspace.rootURL)
        }

        let jobs = context.keepRanges.enumerated().map { index, range in
            SegmentJob(
                index: index,
                startSeconds: max(0, range.start.seconds),
                durationSeconds: max(0.001, range.duration.seconds),
                outputURL: workspace.segmentsDirectoryURL.appendingPathComponent(
                    String(format: "seg_%04d.mp4", index)
                )
            )
        }
        guard !jobs.isEmpty else {
            throw FFmpegComposeError.emptyKeepRanges
        }

        let progressState = SegmentProgressState(
            segmentDurations: jobs.map(\.durationSeconds),
            callback: onProgress
        )
        onProgress?(0)

        let workerLimit = segmentWorkerCount(for: context.performanceProfile)
        let lanes = distributeJobsIntoLanes(
            jobs: jobs,
            laneCount: min(workerLimit, jobs.count)
        )

        switch lanes.count {
        case 1:
            try await runLane(
                lanes[0],
                tools: tools,
                context: context,
                progressState: progressState
            )
        case 2:
            async let lane0 = runLane(
                lanes[0],
                tools: tools,
                context: context,
                progressState: progressState
            )
            async let lane1 = runLane(
                lanes[1],
                tools: tools,
                context: context,
                progressState: progressState
            )
            try await lane0
            try await lane1
        default:
            async let lane0 = runLane(
                lanes[0],
                tools: tools,
                context: context,
                progressState: progressState
            )
            async let lane1 = runLane(
                lanes[1],
                tools: tools,
                context: context,
                progressState: progressState
            )
            async let lane2 = runLane(
                lanes[2],
                tools: tools,
                context: context,
                progressState: progressState
            )
            try await lane0
            try await lane1
            try await lane2
        }

        try writeConcatList(jobs: jobs, to: workspace.concatListURL)
        do {
            let concatCopy = buildConcatCopyCommand(
                tools: tools,
                concatListURL: workspace.concatListURL,
                outputURL: outputURL,
                expectedDurationSeconds: context.expectedOutputDuration
            )
            _ = try await runner.run(command: concatCopy)
        } catch {
            // Fallback: re-encode merge for heterogeneous segment metadata edge cases.
            try removeFileIfExists(at: outputURL)
            let concatReencode = buildConcatReencodeCommand(
                tools: tools,
                context: context,
                concatListURL: workspace.concatListURL,
                outputURL: outputURL
            )
            _ = try await runner.run(command: concatReencode)
        }

        onProgress?(1)
    }

    func runLane(
        _ laneJobs: [SegmentJob],
        tools: FFmpegToolPaths,
        context: ExportContext,
        progressState: SegmentProgressState
    ) async throws {
        for job in laneJobs {
            try Task.checkCancellation()
            let command = buildSegmentCommand(
                tools: tools,
                context: context,
                job: job
            )
            _ = try await runner.run(command: command) { ratio in
                progressState.update(jobIndex: job.index, ratio: ratio)
            }
            progressState.finish(jobIndex: job.index)
        }
    }

    func buildSegmentCommand(
        tools: FFmpegToolPaths,
        context: ExportContext,
        job: SegmentJob
    ) -> FFmpegCommand {
        let encode = videoEncodeSettings(for: context.performanceProfile)
        var args: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-progress", "pipe:1",
            "-i", context.sourceURL.path,
            "-ss", formatTime(job.startSeconds),
            "-t", formatTime(job.durationSeconds),
            "-map", "0:v:0"
        ]

        if !context.isFullCrop {
            let crop = context.cropPixels
            args.append(contentsOf: [
                "-vf",
                "crop=\(Int(crop.width)):\(Int(crop.height)):\(Int(crop.minX)):\(Int(crop.minY))"
            ])
        }

        args.append(contentsOf: [
            "-c:v", "libx264",
            "-preset", encode.preset,
            "-crf", encode.crf,
            "-pix_fmt", "yuv420p"
        ])
        if let threadLimit = encode.threadLimit {
            args.append(contentsOf: ["-threads", String(threadLimit)])
        }

        if context.hasAudioTrack {
            args.append(contentsOf: ["-map", "0:a:0"])
            if let audioFilter = context.audioFilterChain {
                args.append(contentsOf: ["-af", audioFilter])
            }
            args.append(contentsOf: ["-c:a", "aac", "-b:a", "192k"])
        } else {
            args.append("-an")
        }

        args.append(contentsOf: ["-movflags", "+faststart", job.outputURL.path])
        return FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: args,
            expectedDurationSeconds: job.durationSeconds
        )
    }

    func buildConcatCopyCommand(
        tools: FFmpegToolPaths,
        concatListURL: URL,
        outputURL: URL,
        expectedDurationSeconds: Double
    ) -> FFmpegCommand {
        let args: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-progress", "pipe:1",
            "-f", "concat",
            "-safe", "0",
            "-i", concatListURL.path,
            "-c", "copy",
            "-movflags", "+faststart",
            outputURL.path
        ]
        return FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: args,
            expectedDurationSeconds: expectedDurationSeconds
        )
    }

    func buildConcatReencodeCommand(
        tools: FFmpegToolPaths,
        context: ExportContext,
        concatListURL: URL,
        outputURL: URL
    ) -> FFmpegCommand {
        let encode = videoEncodeSettings(for: context.performanceProfile)
        var args: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-progress", "pipe:1",
            "-f", "concat",
            "-safe", "0",
            "-i", concatListURL.path,
            "-map", "0:v:0",
            "-c:v", "libx264",
            "-preset", encode.preset,
            "-crf", encode.crf,
            "-pix_fmt", "yuv420p"
        ]
        if let threadLimit = encode.threadLimit {
            args.append(contentsOf: ["-threads", String(threadLimit)])
        }
        if context.hasAudioTrack {
            args.append(contentsOf: ["-map", "0:a:0", "-c:a", "aac", "-b:a", "192k"])
        } else {
            args.append("-an")
        }
        args.append(contentsOf: ["-movflags", "+faststart", outputURL.path])
        return FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: args,
            expectedDurationSeconds: context.expectedOutputDuration
        )
    }

    func prepareSegmentWorkspace() throws -> SegmentWorkspace {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("VideoCuttingFFmpegSegments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let concatList = root.appendingPathComponent("concat_list.txt")
        try fileManager.createDirectory(at: segments, withIntermediateDirectories: true)
        return SegmentWorkspace(
            rootURL: root,
            segmentsDirectoryURL: segments,
            concatListURL: concatList
        )
    }

    func distributeJobsIntoLanes(jobs: [SegmentJob], laneCount: Int) -> [[SegmentJob]] {
        let safeLaneCount = max(1, min(3, laneCount))
        var lanes = Array(repeating: [SegmentJob](), count: safeLaneCount)
        for (index, job) in jobs.enumerated() {
            lanes[index % safeLaneCount].append(job)
        }
        return lanes
    }

    func writeConcatList(jobs: [SegmentJob], to url: URL) throws {
        var content = "ffconcat version 1.0\n"
        for job in jobs.sorted(by: { $0.index < $1.index }) {
            let escaped = escapeForConcatList(job.outputURL.path)
            content.append("file \(escaped)\n")
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func escapeForConcatList(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    func segmentWorkerCount(
        for profile: VideoCuttingFFmpegProject.PerformanceProfile
    ) -> Int {
        switch profile {
        case .balanced:
            return 2
        case .quality:
            return 3
        }
    }

    func normalizeKeepRanges(_ ranges: [CMTimeRange], sourceDuration: Double) -> [CMTimeRange] {
        let maxDuration = max(0, sourceDuration)
        let normalized = ranges.compactMap { range -> CMTimeRange? in
            let rawStart = max(0, range.start.seconds)
            let rawEnd = max(rawStart, (range.start + range.duration).seconds)
            let start = min(maxDuration, rawStart)
            let end = min(maxDuration, rawEnd)
            guard end - start > 0.0005 else { return nil }
            return CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            )
        }
        return normalized.sorted { $0.start < $1.start }
    }

    func isFullKeep(_ keepRanges: [CMTimeRange], duration: Double) -> Bool {
        guard keepRanges.count == 1 else { return false }
        let range = keepRanges[0]
        return abs(range.start.seconds) <= 0.0005 && abs(range.duration.seconds - duration) <= 0.01
    }

    func isFullCrop(_ cropPixels: CGRect, orientedSize: CGSize) -> Bool {
        abs(cropPixels.minX) <= 1 &&
            abs(cropPixels.minY) <= 1 &&
            abs(cropPixels.width - orientedSize.width) <= 1 &&
            abs(cropPixels.height - orientedSize.height) <= 1
    }

    func cropRectPixels(normalized: CGRect, orientedSize: CGSize) -> CGRect {
        let clamped = VideoCropGeometry.clampNormalizedRect(normalized)
        var x = floor(max(0, clamped.minX * orientedSize.width))
        var y = floor(max(0, clamped.minY * orientedSize.height))
        var width = floor(max(2, min(orientedSize.width - x, clamped.width * orientedSize.width)))
        var height = floor(max(2, min(orientedSize.height - y, clamped.height * orientedSize.height)))

        if Int(width) % 2 != 0 {
            width = max(2, width - 1)
        }
        if Int(height) % 2 != 0 {
            height = max(2, height - 1)
        }

        if x + width > orientedSize.width {
            x = max(0, orientedSize.width - width)
        }
        if y + height > orientedSize.height {
            y = max(0, orientedSize.height - height)
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    func buildAudioFilterChain(config: VideoCuttingAudioProcessingConfig) -> String? {
        let cfg = config.clamped
        guard cfg.hasAnyProcessing else { return nil }

        var filters: [String] = []

        if cfg.noiseReductionEnabled {
            let p = max(0, min(100, cfg.noiseReductionPercent)) / 100.0
            let hp = Int(60 + p * 70)
            let lp = Int(14_000 - p * 5_000)
            let afftdnNR = String(format: "%.2f", 10 + p * 20)
            let afftdnNF = String(format: "%.2f", -55 + p * 10)
            let rejectWidth = String(format: "%.1f", 1.8 + p * 3.2)
            filters.append("highpass=f=\(hp)")
            filters.append("lowpass=f=\(lp)")
            filters.append("bandreject=f=50:t=q:w=\(rejectWidth)")
            filters.append("bandreject=f=60:t=q:w=\(rejectWidth)")
            filters.append("bandreject=f=100:t=q:w=\(rejectWidth)")
            filters.append("bandreject=f=120:t=q:w=\(rejectWidth)")
            filters.append("afftdn=nr=\(afftdnNR):nf=\(afftdnNF):tn=1")
        }

        filters.append(contentsOf: eqFilterChain(for: cfg.eqPreset))
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    func eqFilterChain(for preset: VideoCuttingAudioEQPreset) -> [String] {
        switch preset {
        case .balanced:
            return [
                "equalizer=f=180:t=q:w=0.9:g=-2.5",
                "equalizer=f=2500:t=q:w=1.1:g=2.4",
                "equalizer=f=6200:t=q:w=1.0:g=-1.4"
            ]
        case .vocalBoost:
            return [
                "equalizer=f=200:t=q:w=1.0:g=-1.2",
                "equalizer=f=1800:t=q:w=1.0:g=2.0",
                "equalizer=f=4200:t=q:w=1.2:g=1.8"
            ]
        case .musicBoost:
            return [
                "equalizer=f=120:t=q:w=0.8:g=2.0",
                "equalizer=f=1800:t=q:w=1.0:g=0.8",
                "equalizer=f=8000:t=q:w=1.1:g=1.8"
            ]
        case .loudness:
            return [
                "equalizer=f=120:t=q:w=0.9:g=2.4",
                "equalizer=f=1000:t=q:w=0.9:g=1.2",
                "equalizer=f=7800:t=q:w=1.0:g=2.0"
            ]
        case .humReduction:
            return [
                "bandreject=f=50:t=q:w=3.4",
                "bandreject=f=60:t=q:w=3.4",
                "bandreject=f=100:t=q:w=2.8",
                "bandreject=f=120:t=q:w=2.8",
                "equalizer=f=240:t=q:w=1.0:g=-1.2"
            ]
        case .bassBoost:
            return [
                "equalizer=f=90:t=q:w=0.8:g=3.2",
                "equalizer=f=220:t=q:w=1.0:g=1.4"
            ]
        case .bassCut:
            return [
                "equalizer=f=100:t=q:w=0.9:g=-3.0",
                "equalizer=f=220:t=q:w=1.1:g=-1.3"
            ]
        case .trebleBoost:
            return [
                "equalizer=f=5200:t=q:w=1.2:g=2.6",
                "equalizer=f=9000:t=q:w=1.0:g=2.2"
            ]
        case .trebleCut:
            return [
                "equalizer=f=5200:t=q:w=1.2:g=-2.4",
                "equalizer=f=9000:t=q:w=1.0:g=-2.0"
            ]
        }
    }

    func formatTime(_ seconds: Double) -> String {
        String(format: "%.6f", max(0, seconds))
    }

    func videoEncodeSettings(
        for profile: VideoCuttingFFmpegProject.PerformanceProfile
    ) -> (preset: String, crf: String, threadLimit: Int?) {
        switch profile {
        case .balanced:
            // Inline edit flows (crop/delete reload) favor low CPU usage and responsiveness.
            // Final export still uses quality profile parameters below.
            let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let threadLimit = min(6, max(2, cpuCount / 2))
            return ("ultrafast", "26", threadLimit)
        case .quality:
            return ("medium", "18", nil)
        }
    }

    func removeFileIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private final class SegmentProgressState {
    private let lock = NSLock()
    private let durations: [Double]
    private let totalDuration: Double
    private var ratios: [Double]
    private let callback: ((Double) -> Void)?

    init(segmentDurations: [Double], callback: ((Double) -> Void)?) {
        self.durations = segmentDurations.map { max(0.001, $0) }
        self.totalDuration = max(0.001, durations.reduce(0, +))
        self.ratios = Array(repeating: 0, count: durations.count)
        self.callback = callback
    }

    func update(jobIndex: Int, ratio: Double) {
        let clampedRatio = max(0, min(1, ratio))
        let overall = lockAndComputeProgress(jobIndex: jobIndex, ratio: clampedRatio)
        callback?(overall)
    }

    func finish(jobIndex: Int) {
        let overall = lockAndComputeProgress(jobIndex: jobIndex, ratio: 1)
        callback?(overall)
    }

    private func lockAndComputeProgress(jobIndex: Int, ratio: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard ratios.indices.contains(jobIndex), durations.indices.contains(jobIndex) else {
            return 0
        }
        ratios[jobIndex] = max(ratios[jobIndex], ratio)
        var completed = 0.0
        for index in ratios.indices {
            completed += ratios[index] * durations[index]
        }
        return max(0, min(1, completed / totalDuration))
    }
}

extension VideoCuttingFFmpegExportEngine {
    enum FFmpegComposeError: LocalizedError {
        case missingVideoTrack
        case emptyKeepRanges
        case invalidCropRect
        case invalidRenderSize
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return L10n.tr("legacy.key_175")
            case .emptyKeepRanges:
                return L10n.tr("legacy.key_172")
            case .invalidCropRect:
                return L10n.tr("legacy.key_195")
            case .invalidRenderSize:
                return L10n.tr("legacy.key_196")
            case .outputMissing:
                return L10n.tr("legacy.ffmpeg.output_missing")
            }
        }
    }
}
