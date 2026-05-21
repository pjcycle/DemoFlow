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
            renderSize: cropPixels.size,
            audioProcessingConfig: project.audioProcessingConfig,
            outputURL: project.outputURL
        )

        return try await compose(request: request, sourceAsset: asset, sourceVideoTrack: videoTrack)
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

            var layerConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: videoCompTrack.trackID)
            let transform = cropTransform(
                sourcePreferredTransform: sourcePreferredTransform,
                cropPixels: request.cropPixels
            )
            layerConfig.setTransform(transform, at: timeline)
            let layer = AVVideoCompositionLayerInstruction(configuration: layerConfig)

            let instruction = AVVideoCompositionInstruction(
                configuration: .init(
                    layerInstructions: [layer],
                    timeRange: CMTimeRange(start: timeline, duration: range.duration)
                )
            )
            instructions.append(instruction)

            timeline = timeline + range.duration
        }

        let videoComposition = AVVideoComposition(
            configuration: .init(
                frameDuration: CMTime(value: 1, timescale: 30),
                instructions: instructions,
                renderSize: request.renderSize
            )
        )

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
        cropPixels: CGRect
    ) -> CGAffineTransform {
        // Keep orientation by applying source preferred transform first, then shift cropped top-left to render origin.
        let base = sourcePreferredTransform
        return base.concatenating(CGAffineTransform(translationX: -cropPixels.minX, y: -cropPixels.minY))
    }

    private func orientedSize(of track: AVAssetTrack) async throws -> CGSize {
        try await AVAssetAsyncLoaders.orientedSize(of: track)
    }

    private func removeFileIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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
        case invalidCropRect
        case invalidRenderSize
        case compositionTrackFailed
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
            case .invalidCropRect:
                return L10n.tr("legacy.key_195")
            case .invalidRenderSize:
                return L10n.tr("legacy.key_196")
            case .compositionTrackFailed:
                return L10n.tr("legacy.key_22")
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
