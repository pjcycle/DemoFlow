import AppKit
import AVFoundation
import Foundation

@MainActor
final class WatermarkRemovalService {
    private let binaryService = FFmpegBinaryService()
    private let runner = FFmpegRunner()
    private let fileManager = FileManager.default

    func previewFrame(
        sourceURL: URL,
        timestamp: Double,
        regions: [WatermarkRegion],
        videoSize: CGSize,
        repairPreset: WatermarkRepairPreset,
        outputURL: URL
    ) async throws -> NSImage {
        let tools = try ensureTools()
        try prepareOutput(outputURL)
        let plan = try makeFilterPlan(
            regions: regions,
            videoSize: videoSize,
            repairPreset: repairPreset,
            workingDirectory: outputURL.deletingLastPathComponent()
        )
        defer {
            try? fileManager.removeItem(at: outputURL)
            plan.cleanup()
        }

        var arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-ss", formatSeconds(timestamp),
            "-i", sourceURL.path
        ]
        arguments += plan.imageInputs
        if plan.hasCompositeLayers {
            arguments += [
                "-filter_complex", plan.filter,
                "-map", "[watermark_out]"
            ]
        } else {
            arguments += ["-vf", plan.filter, "-map", "0:v:0"]
        }
        arguments += ["-frames:v", "1", "-f", "image2", outputURL.path]

        let command = FFmpegCommand(
            executableURL: tools.ffmpegURL,
            arguments: arguments,
            expectedDurationSeconds: nil
        )
        do {
            _ = try await runner.run(command: command)
        } catch {
            if Task.isCancelled { throw WatermarkRemovalError.cancelled }
            throw WatermarkRemovalError.commandFailed(error.localizedDescription)
        }
        guard let data = try? Data(contentsOf: outputURL),
              let image = NSImage(data: data),
              image.isValid else {
            throw WatermarkRemovalError.previewFailed
        }
        return image
    }

    func removeWatermarks(
        sourceURL: URL,
        outputURL: URL,
        regions: [WatermarkRegion],
        videoSize: CGSize,
        repairPreset: WatermarkRepairPreset,
        quality: VideoConversionQualityPreset,
        duration: Double,
        onProgress: @escaping (Double) -> Void,
        onLog: @escaping (String) -> Void
    ) async throws {
        let tools = try ensureTools()
        try prepareOutput(outputURL)
        let plan = try makeFilterPlan(
            regions: regions,
            videoSize: videoSize,
            repairPreset: repairPreset,
            workingDirectory: outputURL.deletingLastPathComponent()
        )
        defer { plan.cleanup() }

        var arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-threads", "2",
            "-filter_threads", "2",
            "-i", sourceURL.path
        ]
        arguments += plan.imageInputs
        arguments += ["-map_metadata", "0"]
        if plan.hasCompositeLayers {
            arguments += [
                "-filter_complex", plan.filter,
                "-map", "[watermark_out]"
            ]
        } else {
            arguments += ["-vf", plan.filter, "-map", "0:v:0"]
        }
        arguments += [
            "-map", "0:a:0?",
            "-c:v", "h264_videotoolbox",
            "-profile:v", "high",
            "-b:v", "(quality.videoBitrateMbps)M",
            "-maxrate", "(quality.videoBitrateMbps)M",
            "-bufsize", "(quality.videoBitrateMbps * 2)M",
            "-pix_fmt", "nv12",
            "-power_efficient", "1",
            "-c:a", "aac",
            "-b:a", "(quality.audioBitrateKbps)k",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            "-f", "mp4",
            outputURL.path
        ]
        onLog("[ready] ffmpeg=(tools.ffmpegURL.path)")
        onLog("[ready] ffprobe=(tools.ffprobeURL.path)")
        onLog("[run] (render(arguments, executable: tools.ffmpegURL))")

        do {
            _ = try await runner.run(
                command: FFmpegCommand(
                    executableURL: tools.ffmpegURL,
                    arguments: arguments,
                    expectedDurationSeconds: duration
                ),
                onProgress: onProgress
            )
        } catch {
            if Task.isCancelled { throw WatermarkRemovalError.cancelled }
            throw WatermarkRemovalError.commandFailed(error.localizedDescription)
        }

        try await validateVideo(outputURL)
        onProgress(1)
    }

    private func ensureTools() throws -> FFmpegToolPaths {
        do { return try binaryService.ensureReady() }
        catch { throw WatermarkRemovalError.dependenciesUnavailable }
    }

    // The graph is deliberately built as one chain so preview and full export cannot
    // disagree about layer order: removal, image overlays, then text overlays.
    private func makeFilterPlan(
        regions: [WatermarkRegion],
        videoSize: CGSize,
        repairPreset: WatermarkRepairPreset,
        workingDirectory: URL
    ) throws -> WatermarkFilterPlan {
        guard videoSize.width > 0, videoSize.height > 0 else {
            throw WatermarkRemovalError.invalidRegion
        }

        let delogoFilters = try makeDelogoFilters(
            regions: regions,
            videoSize: videoSize,
            repairPreset: repairPreset
        )
        let imageRegions = regions.compactMap { $0.imageReplacement }
        let textRegions = regions.compactMap { region -> (WatermarkRegion, WatermarkTextReplacement)? in
            guard let text = region.textReplacement, text.isEnabled else { return nil }
            return (region, text)
        }
        let hasCompositeLayers = !imageRegions.isEmpty || !textRegions.isEmpty
        guard !regions.isEmpty else { throw WatermarkRemovalError.invalidRegion }
        if !hasCompositeLayers {
            return WatermarkFilterPlan(
                filter: delogoFilters.joined(separator: ","),
                imageInputs: [],
                textFiles: [],
                hasCompositeLayers: false
            )
        }

        var textFiles: [URL] = []
        for (_, text) in textRegions {
            guard text.font.fileURL.isFileURL,
                  fileManager.fileExists(atPath: text.font.fileURL.path) else {
                throw WatermarkRemovalError.fontUnavailable
            }
            let value = text.text
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw WatermarkRemovalError.invalidTextLayer }
            let textURL = workingDirectory
                .appendingPathComponent(".watermark-text-\(UUID().uuidString).txt")
            guard let data = value.data(using: .utf8) else {
                throw WatermarkRemovalError.invalidTextLayer
            }
            do {
                try data.write(to: textURL, options: .atomic)
                textFiles.append(textURL)
            } catch {
                textFiles.forEach { try? fileManager.removeItem(at: $0) }
                throw WatermarkRemovalError.textFileFailed
            }
        }

        var imageInputs: [String] = []
        var inputIndex = 1
        var graph = "[0:v]\(delogoFilters.joined(separator: ","))[watermark_base]"
        var currentLabel = "watermark_base"

        for image in imageRegions {
            guard fileManager.fileExists(atPath: image.assetURL.path),
                  let imageSource = NSImage(contentsOf: image.assetURL),
                  imageSource.isValid,
                  image.aspectRatio.isFinite,
                  image.aspectRatio > 0 else {
                textFiles.forEach { try? fileManager.removeItem(at: $0) }
                throw WatermarkRemovalError.invalidPNG
            }
            let rect = normalizedReplacementRect(image.rectNormalized)
            let width = max(2, Int((rect.width * videoSize.width).rounded()))
            let height = max(2, Int((rect.height * videoSize.height).rounded()))
            let x = max(0, Int((rect.minX * videoSize.width).rounded(.down)))
            let y = max(0, Int((rect.minY * videoSize.height).rounded(.down)))
            let nextLabel = "watermark_image_\(inputIndex)"
            graph += ";[\(inputIndex):v]scale=w=\(width):h=\(height):force_original_aspect_ratio=decrease[\(nextLabel)_src]"
            graph += ";[\(currentLabel)][\(nextLabel)_src]overlay=x=\(x):y=\(y):shortest=1[\(nextLabel)]"
            imageInputs += ["-loop", "1", "-framerate", "30", "-i", image.assetURL.path]
            currentLabel = nextLabel
            inputIndex += 1
        }

        for (offset, (_, text)) in textRegions.enumerated() {
            guard let textURL = textFiles[safe: offset] else { throw WatermarkRemovalError.textFileFailed }
            let rect = normalizedReplacementRect(text.rectNormalized)
            let fontSize = max(12, Int((rect.height * videoSize.height).rounded()))
            let outlineWidth = text.outlineEnabled
                ? max(1, Int((videoSize.height * CGFloat(text.outlineScale)).rounded()))
                : 0
            let shadowOffset = text.shadowEnabled
                ? max(1, Int((videoSize.height * CGFloat(text.shadowOffsetScale)).rounded()))
                : 0
            let color = ffmpegColor(text.color)
            let fontPath = escapeFilterValue(text.font.fileURL.path)
            let textPath = escapeFilterValue(textURL.path)
            let x = max(0, Int((rect.minX * videoSize.width).rounded(.down)))
            let y = max(0, Int((rect.minY * videoSize.height).rounded(.down)))
            let nextLabel = "watermark_text_\(offset)"
            graph += ";[\(currentLabel)]drawtext=fontfile=\(fontPath):textfile=\(textPath):expansion=none:fontcolor=\(color):fontsize=\(fontSize):x=\(x):y=\(y):borderw=\(outlineWidth):bordercolor=black@0.95:shadowx=\(shadowOffset):shadowy=\(shadowOffset):shadowcolor=black@0.55:fix_bounds=1[\(nextLabel)]"
            currentLabel = nextLabel
        }

        if hasCompositeLayers {
            graph += ";[\(currentLabel)]null[watermark_out]"
        }
        return WatermarkFilterPlan(
            filter: graph,
            imageInputs: imageInputs,
            textFiles: textFiles,
            hasCompositeLayers: hasCompositeLayers
        )
    }

    private func makeDelogoFilters(
        regions: [WatermarkRegion],
        videoSize: CGSize,
        repairPreset: WatermarkRepairPreset
    ) throws -> [String] {
        let maxX = Int(videoSize.width.rounded(.down)) - 1
        let maxY = Int(videoSize.height.rounded(.down)) - 1
        let filters = regions.compactMap { region -> String? in
            let rect = expandedRect(
                VideoCropGeometry.clampNormalizedRect(region.rectNormalized.cgRect),
                padding: repairPreset.paddingScale
            )
            let x = max(0, min(maxX, Int((rect.minX * videoSize.width).rounded(.down))))
            let y = max(0, min(maxY, Int((rect.minY * videoSize.height).rounded(.down))))
            let width = max(2, min(maxX + 1 - x, Int((rect.width * videoSize.width).rounded(.down))))
            let height = max(2, min(maxY + 1 - y, Int((rect.height * videoSize.height).rounded(.down))))
            guard width > 1, height > 1 else { return nil }
            return "delogo=x=(x):y=(y):w=(width):h=(height):show=0"
        }
        guard !filters.isEmpty else { throw WatermarkRemovalError.invalidRegion }
        return filters
    }

    private func normalizedReplacementRect(_ rect: VideoCropRect) -> CGRect {
        VideoCropGeometry.clampNormalizedRect(rect.cgRect)
    }

    private func expandedRect(_ rect: CGRect, padding: CGFloat) -> CGRect {
        guard padding > 0 else { return rect }
        return VideoCropGeometry.clampNormalizedRect(rect.insetBy(dx: -padding, dy: -padding))
    }

    private func ffmpegColor(_ color: SubtitleThemeColor) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        return String(format: "0x%02X%02X%02X@%.4f", red, green, blue, color.opacity)
    }

    private func escapeFilterValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private func validateVideo(_ url: URL) async throws {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw WatermarkRemovalError.outputValidationFailed
        }
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        guard let duration, duration.seconds > 0, tracks?.isEmpty == false else {
            throw WatermarkRemovalError.outputValidationFailed
        }
    }

    private func prepareOutput(_ url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: url)
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", max(0, value))
    }

    private func render(_ arguments: [String], executable: URL) -> String {
        let renderedArguments = arguments.map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
        return "\(executable.path) \(renderedArguments)"
    }
}

private struct WatermarkFilterPlan {
    let filter: String
    let imageInputs: [String]
    let textFiles: [URL]
    let hasCompositeLayers: Bool

    func cleanup() {
        for url in textFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum WatermarkRemovalError: Error {
    case inputUnavailable
    case dependenciesUnavailable
    case invalidRegion
    case invalidPNG
    case fontUnavailable
    case invalidTextLayer
    case textFileFailed
    case previewFailed
    case outputValidationFailed
    case cancelled
    case commandFailed(String)
}
