//
//  PiPFilmRecordingState.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/17.
//

import Foundation

enum PiPFilmRecordingState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .stopping:
            return true
        case .idle, .recording, .failed:
            return false
        }
    }

    var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }
}

enum PiPRecordingQualityPreset: String, CaseIterable, Identifiable, Codable {
    case small
    case balanced
    case highQuality
    case proEditing
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .small:
            return "pip.quality.preset.small"
        case .balanced:
            return "pip.quality.preset.balanced"
        case .highQuality:
            return "pip.quality.preset.high_quality"
        case .proEditing:
            return "pip.quality.preset.pro_editing"
        case .custom:
            return "pip.quality.preset.custom"
        }
    }

    var descriptionKey: String {
        switch self {
        case .small:
            return "pip.quality.preset.small.description"
        case .balanced:
            return "pip.quality.preset.balanced.description"
        case .highQuality:
            return "pip.quality.preset.high_quality.description"
        case .proEditing:
            return "pip.quality.preset.pro_editing.description"
        case .custom:
            return "pip.quality.preset.custom.description"
        }
    }
}

enum PiPRecordingQualityWarningLevel {
    case low
    case high
}

struct PiPRecordingQualityProfile: Equatable {
    let videoBitrateMbps: Int
    let audioBitrateKbps: Int
}

struct PiPRecordingQualityConfig: Equatable, Codable {
    static let minimumBitrateMbps = 1
    static let maximumBitrateMbps = 30
    static let defaultCustomBitrateMbps = 3
    static let defaultAudioBitrateKbps = 128
    static let defaultConfig = PiPRecordingQualityConfig(
        preset: .balanced,
        customVideoBitrateMbps: defaultCustomBitrateMbps
    )

    var preset: PiPRecordingQualityPreset
    var customVideoBitrateMbps: Int

    var resolvedProfile: PiPRecordingQualityProfile {
        switch preset {
        case .small:
            return PiPRecordingQualityProfile(
                videoBitrateMbps: 2,
                audioBitrateKbps: Self.defaultAudioBitrateKbps
            )
        case .balanced:
            return PiPRecordingQualityProfile(
                videoBitrateMbps: 3,
                audioBitrateKbps: Self.defaultAudioBitrateKbps
            )
        case .highQuality:
            return PiPRecordingQualityProfile(
                videoBitrateMbps: 5,
                audioBitrateKbps: Self.defaultAudioBitrateKbps
            )
        case .proEditing:
            return PiPRecordingQualityProfile(
                videoBitrateMbps: 8,
                audioBitrateKbps: Self.defaultAudioBitrateKbps
            )
        case .custom:
            return PiPRecordingQualityProfile(
                videoBitrateMbps: Self.normalizedBitrate(customVideoBitrateMbps),
                audioBitrateKbps: Self.defaultAudioBitrateKbps
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

    func normalized() -> PiPRecordingQualityConfig {
        PiPRecordingQualityConfig(
            preset: preset,
            customVideoBitrateMbps: Self.normalizedBitrate(customVideoBitrateMbps)
        )
    }

    func config(for preset: PiPRecordingQualityPreset) -> PiPRecordingQualityConfig {
        PiPRecordingQualityConfig(
            preset: preset,
            customVideoBitrateMbps: customVideoBitrateMbps
        ).normalized()
    }

    func customWarningLevel() -> PiPRecordingQualityWarningLevel? {
        guard preset == .custom else { return nil }
        let bitrate = resolvedProfile.videoBitrateMbps
        if bitrate < 2 {
            return .low
        }
        if bitrate > 8 {
            return .high
        }
        return nil
    }

    private static func normalizedBitrate(_ bitrate: Int) -> Int {
        min(max(bitrate, minimumBitrateMbps), maximumBitrateMbps)
    }
}
