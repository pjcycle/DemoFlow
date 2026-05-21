//
//  VideoCropModels.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/5.
//

import CoreGraphics
import Foundation

struct VideoCropRect: Equatable, Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    static let full = VideoCropRect(x: 0, y: 0, width: 1, height: 1)
}

struct VideoCuttingComposeProject {
    let sourceURL: URL
    let deleteRanges: [CutRange]
    let cropRectNormalized: VideoCropRect
    let targetAspectPreset: VideoCuttingAspectPreset
    let audioProcessingConfig: VideoCuttingAudioProcessingConfig
    let outputURL: URL
}

enum VideoCropHandle: CaseIterable, Hashable {
    case move
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

extension VideoCuttingAspectPreset {
    var widthOverHeightRatio: CGFloat? {
        switch self {
        case .adaptive:
            return nil
        case .nineBySixteen:
            return 9.0 / 16.0
        case .sixteenByNine:
            return 16.0 / 9.0
        case .oneByOne:
            return 1
        case .fourByThree:
            return 4.0 / 3.0
        case .threeByFour:
            return 3.0 / 4.0
        case .fivePointEight:
            // iPhone X style screen ratio
            return 9.0 / 19.5
        case .twoByOne:
            return 2.0
        case .twoPointThreeFiveByOne:
            return 2.35
        case .onePointEightFiveByOne:
            return 1.85
        }
    }
}
