//
//  TrimExportEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import AVFoundation
import CoreMedia
import Foundation

final class TrimExportEngine {
    func keepRanges(from deleteRanges: [CutRange], sourceDuration: CMTime) -> [CMTimeRange] {
        let mergedDeletes = mergedDeleteRanges(deleteRanges, sourceDuration: sourceDuration)
        guard !mergedDeletes.isEmpty else {
            return [CMTimeRange(start: .zero, duration: sourceDuration)]
        }

        var keep: [CMTimeRange] = []
        var cursor = CMTime.zero

        for deletion in mergedDeletes {
            if deletion.start > cursor {
                keep.append(CMTimeRange(start: cursor, end: deletion.start))
            }
            cursor = deletion.end
        }

        if cursor < sourceDuration {
            keep.append(CMTimeRange(start: cursor, end: sourceDuration))
        }

        return keep.filter { $0.duration > .zero }
    }

    func export(
        project: TrimProject,
        outputURL: URL
    ) async throws -> URL {
        let asset = AVAssetAsyncLoaders.makeURLAsset(project.sourceURL)
        let duration = try await AVAssetAsyncLoaders.duration(of: asset)
        guard let videoTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else {
            throw TrimError.missingVideoTrack
        }

        let keep = keepRanges(from: project.deleteRanges, sourceDuration: duration)
        let request = TrimExportRequest(sourceURL: project.sourceURL, keepRanges: keep, outputURL: outputURL)
        return try await export(request: request, sourceAsset: asset, sourceVideoTrack: videoTrack)
    }

    private func export(
        request: TrimExportRequest,
        sourceAsset: AVAsset,
        sourceVideoTrack: AVAssetTrack
    ) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TrimError.compositionTrackFailed
        }
        let audioCompTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let sourceAudioTrack = try await AVAssetAsyncLoaders.firstTrack(in: sourceAsset, mediaType: .audio)

        var timeline = CMTime.zero
        var instructions: [AVVideoCompositionInstruction] = []
        let renderSize = try await orientedSize(of: sourceVideoTrack)
        let sourcePreferredTransform = try await AVAssetAsyncLoaders.preferredTransform(of: sourceVideoTrack)

        for range in request.keepRanges where range.duration > .zero {
            try videoCompTrack.insertTimeRange(range, of: sourceVideoTrack, at: timeline)
            if let sourceAudioTrack, let audioCompTrack {
                try audioCompTrack.insertTimeRange(range, of: sourceAudioTrack, at: timeline)
            }

            var layerConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: videoCompTrack.trackID)
            layerConfig.setTransform(sourcePreferredTransform, at: timeline)
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
                renderSize: renderSize
            )
        )

        try removeFileIfExists(at: request.outputURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw TrimError.exportSessionFailed
        }

        exporter.outputURL = request.outputURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        do {
            try await AVAssetAsyncLoaders.export(exporter, outputURL: request.outputURL, outputFileType: .mp4)
        } catch is CancellationError {
            throw TrimError.exportCancelled
        } catch {
            throw TrimError.exportFailed
        }

        return request.outputURL
    }

    private func mergedDeleteRanges(
        _ ranges: [CutRange],
        sourceDuration: CMTime
    ) -> [CMTimeRange] {
        let normalizedRanges = ranges
            .map { $0.normalized }
            .map {
                CMTimeRange(
                    start: CMTimeMaximum(.zero, $0.start),
                    end: CMTimeMinimum(sourceDuration, $0.end)
                )
            }
            .filter { $0.duration > .zero }
            .sorted { $0.start < $1.start }

        guard var current = normalizedRanges.first else { return [] }
        var merged: [CMTimeRange] = []

        for range in normalizedRanges.dropFirst() {
            if range.start <= current.end {
                current = CMTimeRange(start: current.start, end: CMTimeMaximum(current.end, range.end))
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
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

extension TrimExportEngine {
    enum TrimError: LocalizedError {
        case missingVideoTrack
        case compositionTrackFailed
        case exportSessionFailed
        case exportFailed
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return L10n.tr("legacy.key_175")
            case .compositionTrackFailed:
                return L10n.tr("legacy.key_22")
            case .exportSessionFailed:
                return L10n.tr("legacy.key_23")
            case .exportFailed:
                return L10n.tr("legacy.key_32")
            case .exportCancelled:
                return L10n.tr("legacy.key_33")
            }
        }
    }
}
