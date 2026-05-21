//
//  VideoCuttingAspectPreset.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import Foundation

enum VideoCuttingAspectPreset: String, CaseIterable, Identifiable {
    case adaptive
    case nineBySixteen
    case sixteenByNine
    case oneByOne
    case fourByThree
    case threeByFour
    case fivePointEight
    case twoByOne
    case twoPointThreeFiveByOne
    case onePointEightFiveByOne

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive:
            return L10n.tr("legacy.key_210")
        case .nineBySixteen:
            return "9:16"
        case .sixteenByNine:
            return "16:9"
        case .oneByOne:
            return "1:1"
        case .fourByThree:
            return "4:3"
        case .threeByFour:
            return "3:4"
        case .fivePointEight:
            return "5.8\""
        case .twoByOne:
            return "2:1"
        case .twoPointThreeFiveByOne:
            return "2.35:1"
        case .onePointEightFiveByOne:
            return "1.85:1"
        }
    }
}
