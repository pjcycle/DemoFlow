//
//  RecordingState.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import Foundation

enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .stopping:
            return true
        case .idle, .recording, .failed:
            return false
        }
    }

    var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }
}
