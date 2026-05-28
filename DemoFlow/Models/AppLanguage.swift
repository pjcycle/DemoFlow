//
//  AppLanguage.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import Foundation

enum AppLanguageOption: String, CaseIterable, Identifiable, Codable {
    case auto
    case zhHans
    case en

    var id: String { rawValue }
}

enum ResolvedAppLanguage: String, Codable {
    case zhHans
    case en

    var locale: Locale {
        switch self {
        case .zhHans:
            return Locale(identifier: "zh-Hans")
        case .en:
            return Locale(identifier: "en")
        }
    }

    var lprojName: String {
        switch self {
        case .zhHans:
            return "zh-Hans"
        case .en:
            return "en"
        }
    }

    static func resolve(option: AppLanguageOption, regionIdentifier: String?) -> ResolvedAppLanguage {
        switch option {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .auto:
            return regionIdentifier?.uppercased() == "CN" ? .zhHans : .en
        }
    }
}

