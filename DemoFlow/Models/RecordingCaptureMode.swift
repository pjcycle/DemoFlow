//
//  RecordingCaptureMode.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/25.
//

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
