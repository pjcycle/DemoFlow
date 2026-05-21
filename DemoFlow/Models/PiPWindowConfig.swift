//
//  PiPWindowConfig.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import Foundation

enum PiPWindowFrameStyle: String, Codable, CaseIterable, Identifiable {
    case square
    case circle

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .square:
            return L10n.tr("legacy.key_151")
        case .circle:
            return L10n.tr("legacy.key_42")
        }
    }
}

struct PiPWindowConfig: Equatable, Codable {
    var isAlwaysOnTop: Bool
    var isTitleBarVisible: Bool
    var frameStyle: PiPWindowFrameStyle
    var windowTitle: String

    static let defaultWindowTitle = L10n.tr("legacy.pj_lee")

    var resolvedWindowTitle: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultWindowTitle : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case isAlwaysOnTop
        case isTitleBarVisible
        case frameStyle
        case windowTitle
    }

    init(
        isAlwaysOnTop: Bool = true,
        isTitleBarVisible: Bool = true,
        frameStyle: PiPWindowFrameStyle = .square,
        windowTitle: String = defaultWindowTitle
    ) {
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isTitleBarVisible = isTitleBarVisible
        self.frameStyle = frameStyle
        self.windowTitle = windowTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .isAlwaysOnTop) ?? true
        isTitleBarVisible = try container.decodeIfPresent(Bool.self, forKey: .isTitleBarVisible) ?? true
        if let rawFrameStyle = try container.decodeIfPresent(String.self, forKey: .frameStyle) {
            frameStyle = PiPWindowFrameStyle(rawValue: rawFrameStyle) ?? .square
        } else {
            frameStyle = .square
        }
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle) ?? Self.defaultWindowTitle
    }

    static let `default` = PiPWindowConfig()
}
