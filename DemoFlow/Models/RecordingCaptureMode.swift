//
//  RecordingCaptureMode.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/25.
//

import CoreGraphics
import Foundation

enum RecordingCaptureMode: String, CaseIterable, Identifiable, Codable {
    case fullScreen
    case region

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .fullScreen:
            return "recording.capture_mode.full_screen"
        case .region:
            return "recording.capture_mode.region"
        }
    }
}

enum RecordingFixedCapturePreset: String, CaseIterable, Identifiable {
    case desktopQHD
    case desktopFullHD
    case desktopHD
    case mobileQHD
    case mobileFullHD
    case mobileHD

    var id: String { rawValue }

    var aspectLabel: String {
        switch self {
        case .desktopQHD, .desktopFullHD, .desktopHD:
            return "16:9"
        case .mobileQHD, .mobileFullHD, .mobileHD:
            return "9:16"
        }
    }

    var pixelSize: CGSize {
        switch self {
        case .desktopQHD:
            return CGSize(width: 2560, height: 1440)
        case .desktopFullHD:
            return CGSize(width: 1920, height: 1080)
        case .desktopHD:
            return CGSize(width: 1280, height: 720)
        case .mobileQHD:
            return CGSize(width: 1080, height: 1920)
        case .mobileFullHD:
            return CGSize(width: 720, height: 1280)
        case .mobileHD:
            return CGSize(width: 540, height: 960)
        }
    }

    var displayText: String {
        let size = pixelSize
        return "\(Int(size.width)) x \(Int(size.height))"
    }
}
