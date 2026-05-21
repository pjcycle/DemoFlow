//
//  VideoCuttingAudioModels.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/5.
//

import Foundation

enum VideoCuttingAudioEQPreset: String, CaseIterable, Identifiable, Codable {
    case balanced
    case vocalBoost
    case musicBoost
    case loudness
    case humReduction
    case bassBoost
    case bassCut
    case trebleBoost
    case trebleCut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return L10n.tr("legacy.key_95")
        case .vocalBoost:
            return L10n.tr("legacy.key_7")
        case .musicBoost:
            return L10n.tr("legacy.key_219")
        case .loudness:
            return L10n.tr("legacy.key_38")
        case .humReduction:
            return L10n.tr("legacy.key_39")
        case .bassBoost:
            return L10n.tr("legacy.key_9")
        case .bassCut:
            return L10n.tr("legacy.key_8")
        case .trebleBoost:
            return L10n.tr("legacy.key_227")
        case .trebleCut:
            return L10n.tr("legacy.key_226")
        }
    }
}

struct VideoCuttingAudioProcessingConfig: Equatable, Codable {
    var noiseReductionEnabled: Bool
    var noiseReductionPercent: Double
    var eqPreset: VideoCuttingAudioEQPreset

    static let `default` = VideoCuttingAudioProcessingConfig(
        noiseReductionEnabled: false,
        noiseReductionPercent: 50,
        eqPreset: .balanced
    )

    var clamped: VideoCuttingAudioProcessingConfig {
        VideoCuttingAudioProcessingConfig(
            noiseReductionEnabled: noiseReductionEnabled,
            noiseReductionPercent: max(0, min(100, noiseReductionPercent)),
            eqPreset: eqPreset
        )
    }

    var hasAnyProcessing: Bool {
        clamped.noiseReductionEnabled || clamped.eqPreset != .balanced
    }
}
