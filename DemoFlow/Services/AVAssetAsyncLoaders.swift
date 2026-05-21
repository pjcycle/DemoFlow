//
//  AVAssetAsyncLoaders.swift
//  DemoFlow
//
//  Created by Codex on 2026/5/17.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

enum AVAssetAsyncLoaders {
    static func makeURLAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url)
    }

    static func firstTrack(in asset: AVAsset, mediaType: AVMediaType) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        return tracks.first
    }

    static func duration(of asset: AVAsset) async throws -> CMTime {
        try await asset.load(.duration)
    }

    static func orientedSize(of track: AVAssetTrack) async throws -> CGSize {
        let natural = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    static func nominalFrameRate(of track: AVAssetTrack) async throws -> Float {
        try await track.load(.nominalFrameRate)
    }

    static func minFrameDuration(of track: AVAssetTrack) async throws -> CMTime {
        try await track.load(.minFrameDuration)
    }

    static func preferredTransform(of track: AVAssetTrack) async throws -> CGAffineTransform {
        try await track.load(.preferredTransform)
    }

    static func export(
        _ exporter: AVAssetExportSession,
        outputURL: URL,
        outputFileType: AVFileType
    ) async throws {
        try await exporter.export(to: outputURL, as: outputFileType)
    }
}
