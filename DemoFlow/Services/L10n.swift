//
//  L10n.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import Foundation
import SwiftUI

enum L10n {
    static let optionAuto = "language.option.auto"
    static let optionChinese = "language.option.zhHans"
    static let optionEnglish = "language.option.en"

    private static var activeLanguage: ResolvedAppLanguage = .en
    private static var activeBundle: Bundle = .main
    private static let tableName = "Localizable"

    static func setLanguage(_ language: ResolvedAppLanguage) {
        activeLanguage = language
        activeBundle = bundle(for: language) ?? .main
    }

    static func tr(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: tableName,
            bundle: activeBundle,
            value: key,
            comment: ""
        )
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        f(key, args)
    }

    static func f(_ key: String, _ args: [CVarArg]) -> String {
        let format = tr(key)
        return String(format: format, locale: activeLanguage.locale, arguments: args)
    }

    static func text(_ key: String) -> Text {
        Text(LocalizedStringKey(key))
    }

    private static func bundle(for language: ResolvedAppLanguage) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language.lprojName, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}

