//
//  CompositionExportEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import AVFoundation
import CoreMedia
import Foundation

final class CompositionExportEngine {
    func mergeScreenAndCamera(
        screenURL: URL,
        cameraURL: URL?,
        pipLayout: PiPLayoutState,
        faceFramingKeyframes: [FaceFramingKeyframe] = [],
        outputURL: URL
    ) async throws -> URL {
        guard let cameraURL else {
            try removeFileIfExists(at: outputURL)
            try FileManager.default.copyItem(at: screenURL, to: outputURL)
            return outputURL
        }

        let screenAsset = AVAssetAsyncLoaders.makeURLAsset(screenURL)
        let cameraAsset = AVAssetAsyncLoaders.makeURLAsset(cameraURL)
        guard let screenVideoTrack = try await AVAssetAsyncLoaders.firstTrack(in: screenAsset, mediaType: .video) else {
            throw ExportError.missingVideoTrack(L10n.tr("legacy.key_80"))
        }
        guard let cameraVideoTrack = try await AVAssetAsyncLoaders.firstTrack(in: cameraAsset, mediaType: .video) else {
            throw ExportError.missingVideoTrack(L10n.tr("legacy.key_144"))
        }

        let composition = AVMutableComposition()
        guard let screenCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionTrackFailed
        }
        guard let cameraCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionTrackFailed
        }

        let screenDuration = try await AVAssetAsyncLoaders.duration(of: screenAsset)
        try screenCompTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: screenDuration),
            of: screenVideoTrack,
            at: .zero
        )

        let cameraDuration = min(try await AVAssetAsyncLoaders.duration(of: cameraAsset), screenDuration)
        try cameraCompTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: cameraDuration),
            of: cameraVideoTrack,
            at: .zero
        )

        if let screenAudio = try await AVAssetAsyncLoaders.firstTrack(in: screenAsset, mediaType: .audio),
           let audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioCompTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: screenDuration),
                of: screenAudio,
                at: .zero
            )
        }

        let renderSize = try await orientedSize(of: screenVideoTrack)
        var baseLayerConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: screenCompTrack.trackID)
        let screenPreferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: screenVideoTrack)
        baseLayerConfig.setTransform(
            transformToFit(
                preferredTransform: screenPreferredTransform,
                sourceSize: renderSize,
                renderRect: CGRect(origin: .zero, size: renderSize)
            ),
            at: .zero
        )

        let pipRect = CGRect(
            x: pipLayout.normalizedRect.minX * renderSize.width,
            y: pipLayout.normalizedRect.minY * renderSize.height,
            width: pipLayout.normalizedRect.width * renderSize.width,
            height: pipLayout.normalizedRect.height * renderSize.height
        )
        var cameraLayerConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: cameraCompTrack.trackID)
        let cameraSourceSize = try await orientedSize(of: cameraVideoTrack)
        let cameraPreferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: cameraVideoTrack)
        let basePiPTransform = transformToFit(
            preferredTransform: cameraPreferredTransform,
            sourceSize: cameraSourceSize,
            renderRect: pipRect
        )
        cameraLayerConfig.setTransform(basePiPTransform, at: .zero)
        applyFaceFramingTransformRamps(
            keyframes: faceFramingKeyframes,
            to: &cameraLayerConfig,
            cameraSourceSize: cameraSourceSize,
            cameraPreferredTransform: cameraPreferredTransform,
            pipRect: pipRect,
            cameraDuration: cameraDuration,
            baseTransform: basePiPTransform
        )

        let cameraLayer = AVVideoCompositionLayerInstruction(configuration: cameraLayerConfig)
        let baseLayer = AVVideoCompositionLayerInstruction(configuration: baseLayerConfig)
        let instruction = AVVideoCompositionInstruction(
            configuration: .init(
                layerInstructions: [cameraLayer, baseLayer],
                timeRange: CMTimeRange(start: .zero, duration: screenDuration)
            )
        )

        let videoComposition = AVVideoComposition(
            configuration: .init(
                frameDuration: CMTime(value: 1, timescale: 30),
                instructions: [instruction],
                renderSize: renderSize
            )
        )

        try await export(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: outputURL
        )
        return outputURL
    }

    func stitch(project: CompositionProject, outputURL: URL) async throws -> URL {
        let baseAsset = AVAssetAsyncLoaders.makeURLAsset(project.baseAssetURL)
        guard let baseVideoTrack = try await AVAssetAsyncLoaders.firstTrack(in: baseAsset, mediaType: .video) else {
            throw ExportError.missingVideoTrack(L10n.tr("legacy.key_6"))
        }

        let renderSize = try await orientedSize(of: baseVideoTrack)
        let baseDuration = try await AVAssetAsyncLoaders.duration(of: baseAsset)
        let insertions = project.layers.sorted { $0.insertTime < $1.insertTime }
        let basePreferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: baseVideoTrack)
        let baseSourceSize = try await orientedSize(of: baseVideoTrack)

        let composition = AVMutableComposition()
        guard let videoCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionTrackFailed
        }
        let audioCompTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        struct Segment {
            let timeRange: CMTimeRange
            let sourceTrack: AVAssetTrack
            let preferredTransform: CGAffineTransform
            let sourceSize: CGSize
        }
        var segments: [Segment] = []

        var cursor = CMTime.zero
        var timeline = CMTime.zero

        func appendSegment(
            from asset: AVAsset,
            videoTrack: AVAssetTrack,
            preferredTransform: CGAffineTransform,
            sourceSize: CGSize,
            range: CMTimeRange,
            muteAudio: Bool
        ) async throws {
            try videoCompTrack.insertTimeRange(range, of: videoTrack, at: timeline)
            segments.append(
                Segment(
                    timeRange: CMTimeRange(start: timeline, duration: range.duration),
                    sourceTrack: videoTrack,
                    preferredTransform: preferredTransform,
                    sourceSize: sourceSize
                )
            )

            if !muteAudio,
               let sourceAudioTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio),
               let audioCompTrack {
                try audioCompTrack.insertTimeRange(range, of: sourceAudioTrack, at: timeline)
            }
            timeline = timeline + range.duration
        }

        for insertion in insertions {
            let insertionPoint = CMTimeMaximum(CMTime.zero, CMTimeMinimum(baseDuration, insertion.insertTime))
            if insertionPoint > cursor {
                let baseRange = CMTimeRange(start: cursor, end: insertionPoint)
                if baseRange.duration > .zero {
                    try await appendSegment(
                        from: baseAsset,
                        videoTrack: baseVideoTrack,
                        preferredTransform: basePreferredTransform,
                        sourceSize: baseSourceSize,
                        range: baseRange,
                        muteAudio: false
                    )
                }
            }

            let insertAsset = AVAssetAsyncLoaders.makeURLAsset(insertion.assetURL)
            guard let insertVideoTrack = try await AVAssetAsyncLoaders.firstTrack(in: insertAsset, mediaType: .video) else {
                throw ExportError.missingVideoTrack(
                    L10n.f("fmt.compose.insertion_missing_video", insertion.assetURL.lastPathComponent)
                )
            }
            let insertRange = CMTimeRange(start: .zero, duration: try await AVAssetAsyncLoaders.duration(of: insertAsset))
            let insertPreferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: insertVideoTrack)
            let insertSourceSize = try await orientedSize(of: insertVideoTrack)
            if insertRange.duration > .zero {
                try await appendSegment(
                    from: insertAsset,
                    videoTrack: insertVideoTrack,
                    preferredTransform: insertPreferredTransform,
                    sourceSize: insertSourceSize,
                    range: insertRange,
                    muteAudio: insertion.mute
                )
            }
            cursor = insertionPoint
        }

        if cursor < baseDuration {
            let tailRange = CMTimeRange(start: cursor, end: baseDuration)
            if tailRange.duration > .zero {
                try await appendSegment(
                    from: baseAsset,
                    videoTrack: baseVideoTrack,
                    preferredTransform: basePreferredTransform,
                    sourceSize: baseSourceSize,
                    range: tailRange,
                    muteAudio: false
                )
            }
        }

        let instructions: [AVVideoCompositionInstruction] = segments.map { segment in
            var layerConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: videoCompTrack.trackID)
            layerConfig.setTransform(
                transformToFit(
                    preferredTransform: segment.preferredTransform,
                    sourceSize: segment.sourceSize,
                    renderRect: CGRect(origin: .zero, size: renderSize)
                ),
                at: segment.timeRange.start
            )
            let layer = AVVideoCompositionLayerInstruction(configuration: layerConfig)
            return AVVideoCompositionInstruction(
                configuration: .init(
                    layerInstructions: [layer],
                    timeRange: segment.timeRange
                )
            )
        }
        let videoComposition = AVVideoComposition(
            configuration: .init(
                frameDuration: CMTime(value: 1, timescale: 30),
                instructions: instructions,
                renderSize: renderSize
            )
        )

        try await export(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: outputURL
        )
        return outputURL
    }

    private func export(
        composition: AVMutableComposition,
        videoComposition: AVVideoComposition?,
        outputURL: URL
    ) async throws {
        try removeFileIfExists(at: outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportSessionFailed
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        do {
            try await AVAssetAsyncLoaders.export(exporter, outputURL: outputURL, outputFileType: .mp4)
        } catch is CancellationError {
            throw ExportError.exportCancelled
        } catch {
            throw ExportError.exportFailed
        }
    }

    private func orientedSize(of track: AVAssetTrack) async throws -> CGSize {
        try await AVAssetAsyncLoaders.orientedSize(of: track)
    }

    private func transformToFit(
        preferredTransform baseTransform: CGAffineTransform,
        sourceSize: CGSize,
        renderRect: CGRect
    ) -> CGAffineTransform {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return baseTransform }

        let scale = min(renderRect.width / sourceSize.width, renderRect.height / sourceSize.height)
        let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let x = renderRect.minX + (renderRect.width - targetSize.width) / 2.0
        let y = renderRect.minY + (renderRect.height - targetSize.height) / 2.0

        return baseTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x / scale, y: y / scale))
    }

    private func applyFaceFramingTransformRamps(
        keyframes: [FaceFramingKeyframe],
        to layerConfig: inout AVVideoCompositionLayerInstruction.Configuration,
        cameraSourceSize: CGSize,
        cameraPreferredTransform: CGAffineTransform,
        pipRect: CGRect,
        cameraDuration: CMTime,
        baseTransform: CGAffineTransform
    ) {
        guard !keyframes.isEmpty else { return }
        guard cameraDuration.seconds > 0 else { return }

        let validFrames = keyframes
            .map { frame in
                FaceFramingKeyframe(
                    id: frame.id,
                    seconds: max(0, min(cameraDuration.seconds, frame.seconds)),
                    normalizedRect: PiPGeometry.clampNormalized(frame.normalizedRect)
                )
            }
            .sorted { $0.seconds < $1.seconds }

        guard validFrames.count >= 2 else {
            if let single = validFrames.first {
                let transform = transformForFaceFrame(
                    single,
                    cameraSourceSize: cameraSourceSize,
                    cameraPreferredTransform: cameraPreferredTransform,
                    pipRect: pipRect,
                    fallback: baseTransform
                )
                layerConfig.setTransform(transform, at: CMTime(seconds: single.seconds, preferredTimescale: 600))
            }
            return
        }

        for idx in 0..<(validFrames.count - 1) {
            let current = validFrames[idx]
            let next = validFrames[idx + 1]
            guard next.seconds > current.seconds else { continue }

            let fromTransform = transformForFaceFrame(
                current,
                cameraSourceSize: cameraSourceSize,
                cameraPreferredTransform: cameraPreferredTransform,
                pipRect: pipRect,
                fallback: baseTransform
            )
            let toTransform = transformForFaceFrame(
                next,
                cameraSourceSize: cameraSourceSize,
                cameraPreferredTransform: cameraPreferredTransform,
                pipRect: pipRect,
                fallback: baseTransform
            )

            layerConfig.addTransformRamp(
                .init(
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: current.seconds, preferredTimescale: 600),
                        duration: CMTime(seconds: next.seconds - current.seconds, preferredTimescale: 600)
                    ),
                    start: fromTransform,
                    end: toTransform
                )
            )
        }
    }

    private func transformForFaceFrame(
        _ frame: FaceFramingKeyframe,
        cameraSourceSize: CGSize,
        cameraPreferredTransform: CGAffineTransform,
        pipRect: CGRect,
        fallback: CGAffineTransform
    ) -> CGAffineTransform {
        let normalized = PiPGeometry.clampNormalized(frame.normalizedRect)
        guard normalized.width > 0.001, normalized.height > 0.001 else { return fallback }

        let sourceSize = cameraSourceSize
        guard sourceSize.width > 1, sourceSize.height > 1 else { return fallback }

        let cropRect = CGRect(
            x: normalized.minX * sourceSize.width,
            y: normalized.minY * sourceSize.height,
            width: normalized.width * sourceSize.width,
            height: normalized.height * sourceSize.height
        )
        guard cropRect.width > 1, cropRect.height > 1 else { return fallback }

        return transformToFit(
            preferredTransform: cameraPreferredTransform,
            sourceSize: cropRect.size,
            renderRect: pipRect
        )
            .concatenating(
                CGAffineTransform(translationX: -(cropRect.minX), y: -(cropRect.minY))
            )
    }

    private func removeFileIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

extension CompositionExportEngine {
    enum ExportError: LocalizedError {
        case missingVideoTrack(String)
        case compositionTrackFailed
        case exportSessionFailed
        case exportFailed
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case let .missingVideoTrack(message):
                return message
            case .compositionTrackFailed:
                return L10n.tr("legacy.key_22")
            case .exportSessionFailed:
                return L10n.tr("legacy.key_23")
            case .exportFailed:
                return L10n.tr("legacy.key_58")
            case .exportCancelled:
                return L10n.tr("legacy.key_63")
            }
        }
    }
}
