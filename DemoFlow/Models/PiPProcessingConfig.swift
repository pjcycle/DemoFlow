//
//  PiPProcessingConfig.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import Foundation

struct PiPProcessingConfig: Equatable, Codable {
    var faceFramingEnabled: Bool
    var ciEnhancementEnabled: Bool
    var smoothingFactor: Double
    var minCropScale: Double
    var maxCropScale: Double

    static let `default` = PiPProcessingConfig(
        faceFramingEnabled: true,
        ciEnhancementEnabled: true,
        smoothingFactor: 0.20,
        minCropScale: 1.0,
        maxCropScale: 2.2
    )

    var clampedSmoothing: Double {
        min(1, max(0, smoothingFactor))
    }

    var clampedMinCropScale: Double {
        max(1, minCropScale)
    }

    var clampedMaxCropScale: Double {
        max(clampedMinCropScale, maxCropScale)
    }
}
