//
//  ScreenDrawMarkStyle.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import Foundation

enum ScreenDrawMarkStyle: String, CaseIterable, Identifiable {
    case rounded
    case crisp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rounded:
            return L10n.tr("legacy.key_43")
        case .crisp:
            return L10n.tr("legacy.key_30")
        }
    }
}

