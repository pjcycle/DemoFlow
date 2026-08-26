import AppKit
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
#if DEBUG
        writePreviewDiagnostics(
            sourceURL: sourceURL,
            timestamp: timestamp,
            videoSize: videoSize,
            filter: plan.filter,
            command: render(arguments, executable: tools.ffmpegURL),
            failure: nil
        )
#endif
        do {
            _ = try await runner.run(command: command)
        } catch {
#if DEBUG
            writePreviewDiagnostics(
                sourceURL: sourceURL,
                timestamp: timestamp,
                videoSize: videoSize,
                filter: plan.filter,
                command: render(arguments, executable: tools.ffmpegURL),
                failure: error.localizedDescription
            )
#endif
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
            "-b:v", "\(quality.videoBitrateMbps)M",
            "-maxrate", "\(quality.videoBitrateMbps)M",
            "-bufsize", "\(quality.videoBitrateMbps * 2)M",
            "-pix_fmt", "nv12",
            "-power_efficient", "1",
            "-c:a", "aac",
            "-b:a", "\(quality.audioBitrateKbps)k",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-nostats",
            "-f", "mp4",
            outputURL.path
        ]
        onLog("[ready] ffmpeg=\(tools.ffmpegURL.path)")
        onLog("[ready] ffprobe=\(tools.ffprobeURL.path)")
        onLog("[run] \(render(arguments, executable: tools.ffmpegURL))")

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

        try validateVideo(
            outputURL,
            ffprobeURL: tools.ffprobeURL,
            onLog: onLog
        )
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

        let delogoGuardBand = 16
        let delogoFilters = try makeDelogoFilters(
            regions: regions,
            videoSize: videoSize,
            repairPreset: repairPreset,
            coordinateOffset: delogoGuardBand
        )
        let delogoChain = makeDelogoChain(delogoFilters, guardBand: delogoGuardBand)
        let imageRegions = regions.compactMap { $0.imageReplacement }
        let textRegions = regions.compactMap { region -> (WatermarkRegion, WatermarkTextReplacement)? in
            guard let text = region.textReplacement, text.isEnabled else { return nil }
            return (region, text)
        }
        let hasCompositeLayers = !imageRegions.isEmpty || !textRegions.isEmpty
        guard !regions.isEmpty else { throw WatermarkRemovalError.invalidRegion }
        if !hasCompositeLayers {
            return WatermarkFilterPlan(
                filter: delogoChain,
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
        var graph = "[0:v]\(delogoChain)[watermark_base]"
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
        repairPreset: WatermarkRepairPreset,
        coordinateOffset: Int
    ) throws -> [String] {
        let frameWidth = Int(videoSize.width.rounded(.down))
        let frameHeight = Int(videoSize.height.rounded(.down))
        // FFmpeg's delogo rejects a box touching the right or bottom edge, so
        // preserve one pixel of frame space beyond every requested region.
        guard frameWidth >= 3, frameHeight >= 3 else {
            throw WatermarkRemovalError.invalidRegion
        }
        let filters = regions.compactMap { region -> String? in
            let rect = expandedRect(
                VideoCropGeometry.clampNormalizedRect(region.rectNormalized.cgRect),
                padding: repairPreset.paddingScale
            )
            let requestedWidth = max(2, Int((rect.width * videoSize.width).rounded(.down)))
            let requestedHeight = max(2, Int((rect.height * videoSize.height).rounded(.down)))
            let x = min(
                max(0, Int((rect.minX * videoSize.width).rounded(.down))),
                frameWidth - 3
            )
            let y = min(
                max(0, Int((rect.minY * videoSize.height).rounded(.down))),
                frameHeight - 3
            )
            let width = min(requestedWidth, frameWidth - x - 1)
            let height = min(requestedHeight, frameHeight - y - 1)
            guard width > 1, height > 1 else { return nil }
            return "delogo=x=\(x + coordinateOffset):y=\(y + coordinateOffset):w=\(width):h=\(height):show=0"
        }
        guard !filters.isEmpty else { throw WatermarkRemovalError.invalidRegion }
        return filters
    }

    private func makeDelogoChain(_ filters: [String], guardBand: Int) -> String {
        // delogo needs repair pixels beyond all four sides of a selected region.
        // Expand all sides, shift regions inward, then restore the source canvas.
        let doubledGuardBand = guardBand * 2
        return "pad=iw+\(doubledGuardBand):ih+\(doubledGuardBand):\(guardBand):\(guardBand):color=black,\(filters.joined(separator: ",")),crop=iw-\(doubledGuardBand):ih-\(doubledGuardBand):\(guardBand):\(guardBand)"
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

    private func validateVideo(
        _ url: URL,
        ffprobeURL: URL,
        onLog: @escaping (String) -> Void
    ) throws {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw WatermarkRemovalError.outputValidationFailed
        }

        let durationCommand = WatermarkProbeCommand(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path
            ]
        )
        onLog("[verify] \(durationCommand.rendered)")
        let durationOutput = try runProbe(durationCommand)
        let duration = durationOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first ?? 0
        guard duration > 0 else {
            throw WatermarkRemovalError.outputValidationFailed
        }

        let videoTrackCommand = WatermarkProbeCommand(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=codec_type",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path
            ]
        )
        onLog("[verify] \(videoTrackCommand.rendered)")
        let videoTrackOutput = try runProbe(videoTrackCommand)
        guard videoTrackOutput.contains("video") else {
            throw WatermarkRemovalError.outputValidationFailed
        }
    }

    private func runProbe(_ command: WatermarkProbeCommand) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WatermarkRemovalError.probeFailed(error.localizedDescription)
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw WatermarkRemovalError.probeFailed(text)
        }
        return text
    }

    private func prepareOutput(_ url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: url)
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", max(0, value))
    }

#if DEBUG
    private func writePreviewDiagnostics(
        sourceURL: URL,
        timestamp: Double,
        videoSize: CGSize,
        filter: String,
        command: String,
        failure: String?
    ) {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        let url = directory.appendingPathComponent("SubDubWatermarkPreview.log")
        let lines = [
            "source=\(sourceURL.path)",
            "timestamp=\(formatSeconds(timestamp))",
            "videoSize=\(Int(videoSize.width.rounded()))x\(Int(videoSize.height.rounded()))",
            "filter=\(filter)",
            "command=\(command)",
            "failure=\(failure ?? "none")"
        ]
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Diagnostics must never affect preview behavior.
        }
    }
#endif

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

private struct WatermarkProbeCommand {
    let executableURL: URL
    let arguments: [String]

    var rendered: String {
        let renderedArguments = arguments.map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
        return "\(executableURL.path) \(renderedArguments)"
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
    case probeFailed(String)
    case cancelled
    case commandFailed(String)
}
