//
//  ScreenDrawShape.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import AppKit
import Foundation

enum ScreenDrawShapeType: String, CaseIterable, Identifiable {
    case line
    case arrow
    case rectangle
    case ellipse
    case cross
    case check

    var id: String { rawValue }

    var tool: ScreenDrawTool {
        switch self {
        case .line:
            return .line
        case .arrow:
            return .arrow
        case .rectangle:
            return .rectangle
        case .ellipse:
            return .ellipse
        case .cross:
            return .cross
        case .check:
            return .check
        }
    }
}

struct ScreenDrawShape: Identifiable {
    let id: UUID
    let type: ScreenDrawShapeType
    var startPoint: CGPoint
    var endPoint: CGPoint
    var points: [CGPoint]
    var colorPreset: DrawColorPreset
    var lineWidth: CGFloat

    init(
        id: UUID = UUID(),
        type: ScreenDrawShapeType,
        startPoint: CGPoint,
        endPoint: CGPoint,
        points: [CGPoint] = [],
        colorPreset: DrawColorPreset,
        lineWidth: CGFloat = 4
    ) {
        self.id = id
        self.type = type
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.colorPreset = colorPreset
        self.lineWidth = lineWidth
    }

    mutating func translate(by delta: CGPoint) {
        startPoint.x += delta.x
        startPoint.y += delta.y
        endPoint.x += delta.x
        endPoint.y += delta.y
        points = points.map { point in
            CGPoint(x: point.x + delta.x, y: point.y + delta.y)
        }
    }
}
