//
//  PiPAudioPreviewConfig.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import Foundation

struct PiPAudioPreviewConfig: Equatable, Codable {
    var isPreviewMuted: Bool
    var previewVolume: Double

    static let `default` = PiPAudioPreviewConfig(
        isPreviewMuted: true,
        previewVolume: 0.5
    )

    var clampedVolume: Double {
        min(1, max(0, previewVolume))
    }
}
