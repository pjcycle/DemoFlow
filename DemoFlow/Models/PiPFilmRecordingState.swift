//
//  PiPFilmRecordingState.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/17.
//

import Foundation

enum PiPFilmRecordingState: Equatable {
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
