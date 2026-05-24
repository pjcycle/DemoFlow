//
//  RecordingQualityConfig.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/23.
//

import CoreGraphics
import Foundation

enum RecordingQualityPreset: String, CaseIterable, Identifiable, Codable {
    case small
    case balanced
    case highQuality
    case proEditing
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .small:
            return "recording.quality.preset.small"
        case .balanced:
            return "recording.quality.preset.balanced"
        case .highQuality:
            return "recording.quality.preset.high_quality"
        case .proEditing:
            return "recording.quality.preset.pro_editing"
        case .custom:
            return "recording.quality.preset.custom"
        }
    }

    var descriptionKey: String {
        switch self {
        case .small:
            return "recording.quality.preset.small.description"
        case .balanced:
            return "recording.quality.preset.balanced.description"
        case .highQuality:
            return "recording.quality.preset.high_quality.description"
        case .proEditing:
            return "recording.quality.preset.pro_editing.description"
        case .custom:
            return "recording.quality.preset.custom.description"
        }
    }
}

enum RecordingResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case followScreen
    case p1080
    case p2k
    case p4k

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .followScreen:
            return "recording.quality.resolution.follow_screen"
        case .p1080:
            return "recording.quality.resolution.1080p"
        case .p2k:
            return "recording.quality.resolution.2k"
        case .p4k:
            return "recording.quality.resolution.4k"
        }
    }

    func boundingSize(for sourceSize: CGSize) -> CGSize? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let isLandscape = sourceSize.width >= sourceSize.height
        switch self {
        case .followScreen:
            return nil
        case .p1080:
            return isLandscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
        case .p2k:
            return isLandscape ? CGSize(width: 2560, height: 1440) : CGSize(width: 1440, height: 2560)
        case .p4k:
            return isLandscape ? CGSize(width: 3840, height: 2160) : CGSize(width: 2160, height: 3840)
        }
    }
}

enum RecordingVideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264
    case hevc

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .h264:
            return "recording.quality.codec.h264"
        case .hevc:
            return "recording.quality.codec.hevc"
        }
    }
}

enum RecordingQualityWarningLevel {
    case low
    case high
}

struct RecordingQualityProfile: Equatable {
    let resolution: RecordingResolutionPreset
    let fps: Int
    let codec: RecordingVideoCodec
    let videoBitrateMbps: Int
    let audioBitrateKbps: Int
}

struct RecordingQualityConfig: Equatable, Codable {
    static let minimumBitrateMbps = 1
    static let maximumBitrateMbps = 80
    static let defaultFPS = 30
    static let defaultConfig = RecordingQualityConfig(
        preset: .balanced,
        customResolution: .followScreen,
        customFPS: Self.defaultFPS,
        customCodec: .h264,
        customVideoBitrateMbps: 6
    )

    var preset: RecordingQualityPreset
    var customResolution: RecordingResolutionPreset
    var customFPS: Int
    var customCodec: RecordingVideoCodec
    var customVideoBitrateMbps: Int

    var resolvedProfile: RecordingQualityProfile {
        switch preset {
        case .small:
            return RecordingQualityProfile(
                resolution: .p1080,
                fps: 30,
                codec: .h264,
                videoBitrateMbps: 4,
                audioBitrateKbps: 128
            )
        case .balanced:
            return RecordingQualityProfile(
                resolution: .p1080,
                fps: 30,
                codec: .h264,
                videoBitrateMbps: 6,
                audioBitrateKbps: 128
            )
        case .highQuality:
            return RecordingQualityProfile(
                resolution: .p1080,
                fps: 30,
                codec: .h264,
                videoBitrateMbps: 10,
                audioBitrateKbps: 128
            )
        case .proEditing:
            return RecordingQualityProfile(
                resolution: .p2k,
                fps: 30,
                codec: .h264,
                videoBitrateMbps: 16,
                audioBitrateKbps: 128
            )
        case .custom:
            return RecordingQualityProfile(
                resolution: customResolution,
                fps: Self.normalizedFPS(customFPS),
                codec: customCodec,
                videoBitrateMbps: Self.normalizedBitrate(customVideoBitrateMbps),
                audioBitrateKbps: 128
            )
        }
    }

    var estimatedTenMinuteSizeMB: Int {
        estimateSizeMB(durationSeconds: 600)
    }

    func estimateSizeMB(durationSeconds: Int) -> Int {
        let profile = resolvedProfile
        let videoSize = Double(profile.videoBitrateMbps) * Double(durationSeconds) / 8.0
        let audioSize = Double(profile.audioBitrateKbps) / 1000.0 * Double(durationSeconds) / 8.0
        return Int((videoSize + audioSize).rounded())
    }

    func normalized() -> RecordingQualityConfig {
        RecordingQualityConfig(
            preset: preset,
            customResolution: customResolution,
            customFPS: Self.normalizedFPS(customFPS),
            customCodec: customCodec,
            customVideoBitrateMbps: Self.normalizedBitrate(customVideoBitrateMbps)
        )
    }

    func customWarningLevel(for nativeCaptureSize: CGSize?) -> RecordingQualityWarningLevel? {
        guard preset == .custom else { return nil }
        let profile = resolvedProfile
        let effectiveResolution = effectiveResolutionPreset(nativeCaptureSize: nativeCaptureSize)
        let bitrate = profile.videoBitrateMbps
        switch (effectiveResolution, profile.fps) {
        case (.p1080, 30):
            if bitrate < 4 { return .low }
            if bitrate > 16 { return .high }
        case (.p1080, 60):
            if bitrate < 8 { return .low }
        case (.p2k, 30):
            if bitrate < 10 { return .low }
            if bitrate > 30 { return .high }
        case (.p2k, 60):
            if bitrate < 18 { return .low }
        case (.p4k, 30):
            if bitrate < 25 { return .low }
            if bitrate > 60 { return .high }
        case (.p4k, 60):
            if bitrate < 45 { return .low }
        default:
            break
        }
        return nil
    }

    func effectiveResolutionPreset(nativeCaptureSize: CGSize?) -> RecordingResolutionPreset {
        if customResolution != .followScreen {
            return customResolution
        }
        guard let nativeCaptureSize, nativeCaptureSize.width > 0, nativeCaptureSize.height > 0 else {
            return .p1080
        }
        let longestEdge = max(nativeCaptureSize.width, nativeCaptureSize.height)
        if longestEdge >= 3300 {
            return .p4k
        }
        if longestEdge >= 2200 {
            return .p2k
        }
        return .p1080
    }

    static func normalizedBitrate(_ bitrate: Int) -> Int {
        min(max(bitrate, minimumBitrateMbps), maximumBitrateMbps)
    }

    static func normalizedFPS(_ fps: Int) -> Int {
        fps >= 60 ? 60 : 30
    }
}
