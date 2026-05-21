//
//  PiPLayoutState.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import CoreGraphics
import Foundation

struct PiPLayoutState: Equatable, Codable {
    static let minimumSize = CGSize(width: 120, height: 67)

    var normalizedRect: CGRect
    var aspectRatio: PiPAspectRatio

    static let `default` = PiPLayoutState(
        normalizedRect: CGRect(x: 0.60, y: 0.12, width: 0.18, height: 0.18),
        aspectRatio: .auto
    )
}
