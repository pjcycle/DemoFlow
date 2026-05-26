//
//  RecordingRegionSelection.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/25.
//

import CoreGraphics
import Foundation

struct RecordingRegionSelection: Equatable, Codable {
    let displayID: CGDirectDisplayID
    let rectInDisplayPoints: CGRect
}
