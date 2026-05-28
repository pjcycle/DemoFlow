//
//  FaceFramingKeyframe.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import CoreGraphics
import Foundation

struct FaceFramingKeyframe: Equatable, Codable, Identifiable {
    let id: UUID
    let seconds: Double
    let normalizedRect: CGRect

    init(
        id: UUID = UUID(),
        seconds: Double,
        normalizedRect: CGRect
    ) {
        self.id = id
        self.seconds = seconds
        self.normalizedRect = normalizedRect
    }
}
