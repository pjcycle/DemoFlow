//
//  ScreenDrawTool.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import Foundation

enum ScreenDrawTool: String, CaseIterable, Identifiable {
    case line
    case arrow
    case rectangle
    case ellipse
    case cross
    case check

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line:
            return L10n.tr("legacy.key_183")
        case .arrow:
            return L10n.tr("legacy.key_191")
        case .rectangle:
            return L10n.tr("legacy.key_152")
        case .ellipse:
            return L10n.tr("legacy.key_41")
        case .cross:
            return L10n.tr("legacy.key_216")
        case .check:
            return L10n.tr("legacy.key_47")
        }
    }

    var symbolName: String {
        switch self {
        case .line:
            return "curve"
        case .arrow:
            return "arrow.up.right"
        case .rectangle:
            return "rectangle"
        case .ellipse:
            return "circle"
        case .cross:
            return "xmark"
        case .check:
            return "checkmark"
        }
    }
}
