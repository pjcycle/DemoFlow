//
//  RecordingWindowSelection.swift
//  DemoFlow
//
//  2026-08-27 新增：窗口录制模式下用户选中的目标窗口快照。
//

import AppKit
import CoreGraphics
import Foundation

enum RecordingWindowCoordinateSpace {
    static func capturePoint(forCocoaPoint point: CGPoint) -> CGPoint {
        guard let screen = screen(containingCocoaPoint: point),
              let displayID = screen.displayID else {
            return point
        }
        let displayFrame = CGDisplayBounds(displayID)
        let scaleX = displayFrame.width / max(screen.frame.width, 1)
        let scaleY = displayFrame.height / max(screen.frame.height, 1)
        let localX = point.x - screen.frame.minX
        let localY = point.y - screen.frame.minY
        return CGPoint(
            x: displayFrame.minX + localX * scaleX,
            y: displayFrame.minY + (screen.frame.height - localY) * scaleY
        )
    }

    static func displayID(containingCapturePoint point: CGPoint) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            if CGDisplayBounds(displayID).contains(point) {
                return displayID
            }
        }
        return CGMainDisplayID()
    }

    static func captureLocalFrame(forCaptureFrame frame: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        let displayFrame = CGDisplayBounds(displayID)
        let screen = NSScreen.screen(with: displayID)
        let scaleX = displayFrame.width / max(screen?.frame.width ?? displayFrame.width, 1)
        let scaleY = displayFrame.height / max(screen?.frame.height ?? displayFrame.height, 1)
        return CGRect(
            x: (frame.minX - displayFrame.minX) / scaleX,
            y: (frame.minY - displayFrame.minY) / scaleY,
            width: frame.width / scaleX,
            height: frame.height / scaleY
        )
    }

    static func cocoaLocalFrame(
        forCaptureLocalFrame frame: CGRect,
        in screen: NSScreen
    ) -> CGRect {
        return CGRect(
            x: frame.minX,
            y: screen.frame.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func screen(containingCocoaPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

struct RecordingWindowSelection: Equatable, Codable {
    /// 用户点击的主窗口——用于显示录制目标名称。
    let windowID: CGWindowID
    /// 当前屏幕上属于所选应用的全部可见窗口，供 ScreenCaptureKit 录制与窗口跟踪复用。
    let windowIDs: [CGWindowID]
    let displayID: CGDirectDisplayID
    /// 当前选中窗口 frame（display 本地坐标点）；引擎在 buildScreenStream 阶段会重新校准。
    let frameInDisplayPoints: CGRect
    /// 所属应用的 bundle ID
    let ownerBundleID: String?
    /// 应用名（用于状态展示；截断到 64 字符）
    let title: String
}
