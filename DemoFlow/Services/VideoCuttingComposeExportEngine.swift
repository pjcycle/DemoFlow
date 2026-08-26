//
//  VideoCuttingComposeExportEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/5.
//

import AVFoundation
import CoreMedia
import Foundation

final class VideoCuttingComposeExportEngine {
    private let trimEngine = TrimExportEngine()
    private let audioProcessingEngine = VideoCuttingAudioProcessingEngine()

    func export(project: VideoCuttingComposeProject) async throws -> URL {
        let asset = AVAssetAsyncLoaders.makeURLAsset(project.sourceURL)
        let duration = try await AVAssetAsyncLoaders.duration(of: asset)
        guard let videoTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else {
            throw ComposeError.missingVideoTrack
        }

        let keepRanges = trimEngine.keepRanges(from: project.deleteRanges, sourceDuration: duration)
        guard !keepRanges.isEmpty else {
            throw ComposeError.emptyKeepRanges
        }

        let orientedSize = try await orientedSize(of: videoTrack)
        guard orientedSize.width > 1, orientedSize.height > 1 else {
            throw ComposeError.invalidRenderSize
        }

        let normalizedCrop = VideoCropGeometry.clampNormalizedRect(project.cropRectNormalized.cgRect)
        let cropPixels = cropRectPixels(normalized: normalizedCrop, orientedSize: orientedSize)
        guard cropPixels.width > 1, cropPixels.height > 1 else {
            throw ComposeError.invalidCropRect
        }

        let request = ComposeRequest(
            keepRanges: keepRanges,
            cropPixels: cropPixels,
            renderSize: normalizedRenderSize(
                requestedSize: project.targetRenderSize,
                fallbackTo: cropPixels.size
            ),
            audioProcessingConfig: project.audioProcessingConfig,
            outputURL: project.outputURL
        )

        return try await compose(request: request, sourceAsset: asset, sourceVideoTrack: videoTrack)
    }

    func exportTimeline(project: VideoTimelineFFmpegProject) async throws -> URL {
        guard !project.clips.isEmpty else { throw ComposeError.emptyTimeline }

        let composition = AVMutableComposition()
        guard let videoCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ComposeError.compositionTrackFailed
        }

        let audioCompTrack = project.clips.contains(where: \.hasAudioTrack)
            ? composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            : nil
        let normalizedCrop = VideoCropGeometry.clampNormalizedRect(project.cropRectNormalized.cgRect)
        let renderSize = project.renderSize ?? CGSize(width: 1920, height: 1080)
        var instructions: [AVVideoCompositionInstruction] = []
        let starts = project.clips.indices.map { index in
            max(0, project.clipStartSeconds.indices.contains(index) ? project.clipStartSeconds[index] : 0)
        }
        let ordered = project.clips.indices.sorted { starts[$0] < starts[$1] }

        for index in ordered {
            let clip = project.clips[index]
            let asset = AVAssetAsyncLoaders.makeURLAsset(clip.sourceURL)
            guard let sourceVideoTrack = try await AVAssetAsyncLoaders.firstTrack(
                in: asset,
                mediaType: .video
            ) else {
                throw ComposeError.sourceVideoUnavailable(clip.displayName)
            }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: clip.durationSeconds, preferredTimescale: 600)
            )
            let timeline = CMTime(seconds: starts[index], preferredTimescale: 600)
            try videoCompTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: timeline)

            if clip.hasAudioTrack,
               let sourceAudioTrack = try await AVAssetAsyncLoaders.firstTrack(
                   in: asset,
                   mediaType: .audio
               ) {
                try audioCompTrack?.insertTimeRange(sourceRange, of: sourceAudioTrack, at: timeline)
            }

            let orientedSize = try await AVAssetAsyncLoaders.orientedSize(of: sourceVideoTrack)
            let cropPixels = cropRectPixels(normalized: normalizedCrop, orientedSize: orientedSize)
            let preferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: sourceVideoTrack)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoCompTrack)
            layerInstruction.setTransform(
                cropTransform(
                    sourcePreferredTransform: preferredTransform,
                    cropPixels: cropPixels,
                    renderSize: renderSize
                ),
                at: timeline
            )

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: timeline, duration: sourceRange.duration)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize
        videoComposition.instructions = instructions

        let audioMix: AVAudioMix?
        if let audioCompTrack, project.audioProcessingConfig.hasAnyProcessing {
            do {
                audioMix = try audioProcessingEngine.makeAudioMixIfNeeded(
                    track: audioCompTrack,
                    config: project.audioProcessingConfig
                )
            } catch {
                throw ComposeError.audioProcessingFailed(error.localizedDescription)
            }
        } else {
            audioMix = nil
        }

        try removeFileIfExists(at: project.outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ComposeError.exportSessionFailed
        }
        exporter.outputURL = project.outputURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = true

        do {
            try await AVAssetAsyncLoaders.export(
                exporter,
                outputURL: project.outputURL,
                outputFileType: .mp4
            )
        } catch is CancellationError {
            throw ComposeError.exportCancelled
        } catch {
            throw ComposeError.exportFailed
        }
        return project.outputURL
    }

    private func compose(
        request: ComposeRequest,
        sourceAsset: AVAsset,
        sourceVideoTrack: AVAssetTrack
    ) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ComposeError.compositionTrackFailed
        }
        let audioCompTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let sourceAudioTrack = try await AVAssetAsyncLoaders.firstTrack(in: sourceAsset, mediaType: .audio)

        var timeline = CMTime.zero
        var instructions: [AVVideoCompositionInstruction] = []
        let sourcePreferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: sourceVideoTrack)

        for range in request.keepRanges where range.duration > .zero {
            try videoCompTrack.insertTimeRange(range, of: sourceVideoTrack, at: timeline)
            if let sourceAudioTrack, let audioCompTrack {
                try audioCompTrack.insertTimeRange(range, of: sourceAudioTrack, at: timeline)
            }

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoCompTrack)
            let transform = cropTransform(
                sourcePreferredTransform: sourcePreferredTransform,
                cropPixels: request.cropPixels,
                renderSize: request.renderSize
            )
            layerInstruction.setTransform(transform, at: timeline)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: timeline, duration: range.duration)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            timeline = timeline + range.duration
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        videoComposition.renderSize = request.renderSize

        let hasAudioTrack = audioCompTrack != nil && sourceAudioTrack != nil
        let audioMix: AVAudioMix?
        if hasAudioTrack {
            do {
                audioMix = try audioProcessingEngine.makeAudioMixIfNeeded(
                    track: audioCompTrack,
                    config: request.audioProcessingConfig
                )
            } catch {
                throw ComposeError.audioProcessingFailed(error.localizedDescription)
            }
        } else {
            audioMix = nil
        }

        try removeFileIfExists(at: request.outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ComposeError.exportSessionFailed
        }
        exporter.outputURL = request.outputURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = true

        do {
            try await AVAssetAsyncLoaders.export(exporter, outputURL: request.outputURL, outputFileType: .mp4)
        } catch is CancellationError {
            throw ComposeError.exportCancelled
        } catch {
            throw ComposeError.exportFailed
        }

        return request.outputURL
    }

    private func cropRectPixels(normalized: CGRect, orientedSize: CGSize) -> CGRect {
        let clamped = VideoCropGeometry.clampNormalizedRect(normalized)
        var x = clamped.minX * orientedSize.width
        var y = clamped.minY * orientedSize.height
        var width = clamped.width * orientedSize.width
        var height = clamped.height * orientedSize.height

        x = floor(max(0, x))
        y = floor(max(0, y))
        width = floor(max(2, min(orientedSize.width - x, width)))
        height = floor(max(2, min(orientedSize.height - y, height)))

        // H.264-friendly even dimensions.
        if Int(width) % 2 != 0 {
            width = max(2, width - 1)
        }
        if Int(height) % 2 != 0 {
            height = max(2, height - 1)
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func cropTransform(
        sourcePreferredTransform: CGAffineTransform,
        cropPixels: CGRect,
        renderSize: CGSize
    ) -> CGAffineTransform {
        // Keep orientation by applying source preferred transform first, then shift cropped top-left to render origin.
        let base = sourcePreferredTransform
        let translated = base.concatenating(CGAffineTransform(translationX: -cropPixels.minX, y: -cropPixels.minY))
        let scaleX = renderSize.width / max(cropPixels.width, 1)
        let scaleY = renderSize.height / max(cropPixels.height, 1)
        return translated.concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    private func orientedSize(of track: AVAssetTrack) async throws -> CGSize {
        try await AVAssetAsyncLoaders.orientedSize(of: track)
    }

    private func removeFileIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func normalizedRenderSize(
        requestedSize: CGSize?,
        fallbackTo sourceSize: CGSize
    ) -> CGSize {
        guard let requestedSize, requestedSize.width > 1, requestedSize.height > 1 else {
            return sourceSize
        }
        let width = normalizedPixelDimension(requestedSize.width)
        let height = normalizedPixelDimension(requestedSize.height)
        let evenWidth = width
        let evenHeight = height
        guard evenWidth > 1, evenHeight > 1 else { return sourceSize }
        return CGSize(width: evenWidth, height: evenHeight)
    }

    private func normalizedPixelDimension(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded % 2 == 0 ? rounded : max(2, rounded - 1)
    }
}

private extension VideoCuttingComposeExportEngine {
    struct ComposeRequest {
        let keepRanges: [CMTimeRange]
        let cropPixels: CGRect
        let renderSize: CGSize
        let audioProcessingConfig: VideoCuttingAudioProcessingConfig
        let outputURL: URL
    }
}

extension VideoCuttingComposeExportEngine {
    enum ComposeError: LocalizedError {
        case missingVideoTrack
        case emptyKeepRanges
        case emptyTimeline
        case invalidCropRect
        case invalidRenderSize
        case compositionTrackFailed
        case sourceVideoUnavailable(String)
        case exportSessionFailed
        case audioProcessingFailed(String)
        case exportFailed
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return L10n.tr("legacy.key_175")
            case .emptyKeepRanges:
                return L10n.tr("legacy.key_172")
            case .emptyTimeline:
                return L10n.tr("video.cut.timeline.empty")
            case .invalidCropRect:
                return L10n.tr("legacy.key_195")
            case .invalidRenderSize:
                return L10n.tr("legacy.key_196")
            case .compositionTrackFailed:
                return L10n.tr("legacy.key_22")
            case let .sourceVideoUnavailable(name):
                return L10n.f("video.cut.timeline.source_unavailable", name)
            case .exportSessionFailed:
                return L10n.tr("legacy.key_23")
            case let .audioProcessingFailed(message):
                return L10n.f("fmt.video.audio_processing_failed", message)
            case .exportFailed:
                return L10n.tr("legacy.key_130")
            case .exportCancelled:
                return L10n.tr("legacy.key_131")
            }
        }
    }
}
