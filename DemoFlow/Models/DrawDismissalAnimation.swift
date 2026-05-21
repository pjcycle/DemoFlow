//
//  DrawDismissalAnimation.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/8.
//

import Foundation

enum DrawDismissalAnimationMode: String, CaseIterable, Identifiable {
    case random
    case fixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .random:
            return L10n.tr("draw.dismiss.mode.random")
        case .fixed:
            return L10n.tr("draw.dismiss.mode.fixed")
        }
    }
}

enum DrawDismissalAnimationStyle: String, CaseIterable, Identifiable {
    case shatterDrop
    case leftToRight
    case rightToLeft
    case topToBottom
    case bottomToTop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shatterDrop:
            return L10n.tr("draw.dismiss.style.shatter")
        case .leftToRight:
            return L10n.tr("draw.dismiss.style.left_to_right")
        case .rightToLeft:
            return L10n.tr("draw.dismiss.style.right_to_left")
        case .topToBottom:
            return L10n.tr("draw.dismiss.style.top_to_bottom")
        case .bottomToTop:
            return L10n.tr("draw.dismiss.style.bottom_to_top")
        }
    }
}
