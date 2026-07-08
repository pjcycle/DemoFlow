//
//  AudioToolTab.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import Foundation

enum AudioToolTab: String, CaseIterable, Identifiable {
    case extract
    case transcode
    case trim

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .extract:
            return "audio.tool.tab.extract"
        case .transcode:
            return "audio.tool.tab.transcode"
        case .trim:
            return "audio.tool.tab.trim"
        }
    }

    var iconName: String {
        switch self {
        case .extract:
            return "waveform.and.mic"
        case .transcode:
            return "arrow.triangle.2.circlepath"
        case .trim:
            return "scissors"
        }
    }
}
