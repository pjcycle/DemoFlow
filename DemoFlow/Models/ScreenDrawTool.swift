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
    case text
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
        case .text:
            return L10n.tr("draw.text.tool.title")
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
        case .text:
            return "ellipsis.bubble"
        case .check:
            return "checkmark"
        }
    }
}
