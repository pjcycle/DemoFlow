//
//  RecordingRequest.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import CoreGraphics
import Foundation

struct RecordingRequest {
    let microphoneDeviceID: String?
    let cameraDeviceID: String?
    let cameraAudioDeviceID: String?
    let pipWindowID: CGWindowID?
    let screenDrawWindowIDs: [CGWindowID]
    let pipLayout: PiPLayoutState
    let pipAspectRatio: PiPAspectRatio
    let pipProcessingConfig: PiPProcessingConfig
    let pipAudioPreviewConfig: PiPAudioPreviewConfig
}
