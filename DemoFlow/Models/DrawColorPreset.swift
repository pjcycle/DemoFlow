//
//  DrawColorPreset.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import AppKit
import Foundation

enum DrawColorPreset: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one:
            return L10n.tr("legacy.k_1")
        case .two:
            return L10n.tr("legacy.k_2")
        case .three:
            return L10n.tr("legacy.k_3")
        case .four:
            return L10n.tr("legacy.k_4")
        case .five:
            return L10n.tr("legacy.k_5")
        }
    }

    var shortLabel: String {
        "\(rawValue)"
    }

    var displayName: String {
        switch self {
        case .one:
            return L10n.tr("color.red")
        case .two:
            return L10n.tr("color.yellow")
        case .three:
            return L10n.tr("color.green")
        case .four:
            return L10n.tr("color.blue")
        case .five:
            return L10n.tr("color.black")
        }
    }

    var color: NSColor {
        switch self {
        case .one:
            return .systemRed
        case .two:
            return .systemYellow
        case .three:
            return .systemGreen
        case .four:
            return .systemBlue
        case .five:
            return .black
        }
    }
}
