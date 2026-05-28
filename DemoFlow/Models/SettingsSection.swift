//
//  SettingsSection.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case pipCamera
    case screenDrawing
    case videoCutting
    case audioExtract
    case appSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording:
            return L10n.tr("section.recording.title")
        case .pipCamera:
            return L10n.tr("section.pipCamera.title")
        case .screenDrawing:
            return L10n.tr("section.screenDrawing.title")
        case .videoCutting:
            return L10n.tr("section.videoCutting.title")
        case .audioExtract:
            return L10n.tr("section.audioExtract.title")
        case .appSettings:
            return L10n.tr("section.settings.title")
        }
    }

    var subtitle: String {
        switch self {
        case .recording:
            return L10n.tr("section.recording.subtitle")
        case .pipCamera:
            return L10n.tr("section.pipCamera.subtitle")
        case .screenDrawing:
            return L10n.tr("section.screenDrawing.subtitle")
        case .videoCutting:
            return L10n.tr("section.videoCutting.subtitle")
        case .audioExtract:
            return L10n.tr("section.audioExtract.subtitle")
        case .appSettings:
            return L10n.tr("section.settings.subtitle")
        }
    }

    var symbolName: String {
        switch self {
        case .recording:
            return "record.circle"
        case .pipCamera:
            return "video.badge.waveform"
        case .screenDrawing:
            return "pencil.and.scribble"
        case .videoCutting:
            return "scissors"
        case .audioExtract:
            return "waveform.badge.mic"
        case .appSettings:
            return "gearshape"
        }
    }
}
