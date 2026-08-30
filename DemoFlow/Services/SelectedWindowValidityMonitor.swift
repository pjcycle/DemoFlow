//
//  SelectedWindowValidityMonitor.swift
//  DemoFlow
//
//  2026-08-27 新增：监测已选中的目标窗口是否还存在，并同步位置/尺寸变化。
//  窗口关闭或最小化时触发 onLost 回调，让 UI 清掉虚线高亮和 pendingWindowSelection。
//

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class SelectedWindowValidityMonitor {
    struct Update {
        let displayID: CGDirectDisplayID
        let frameInDisplayPoints: CGRect
    }

    private var pollTask: Task<Void, Never>?
    private var targetWindowIDs: Set<CGWindowID> = []
    private var primaryWindowID: CGWindowID?
    private var targetDisplayID: CGDirectDisplayID?
    private var lastDisplayID: CGDirectDisplayID?
    private var lastFrameInDisplayPoints: CGRect?
    private var onUpdate: ((Update) -> Void)?
    private var onLost: (() -> Void)?

    private let pollIntervalNanoseconds: UInt64 = 250_000_000

    var isMonitoring: Bool {
        pollTask != nil
    }

    func startMonitoring(
        windowIDs: [CGWindowID],
        displayID: CGDirectDisplayID,
        onUpdate: @escaping (Update) -> Void,
        onLost: @escaping () -> Void
    ) {
        stopMonitoring()
        targetWindowIDs = Set(windowIDs)
        primaryWindowID = windowIDs.first
        targetDisplayID = displayID
        lastDisplayID = nil
        lastFrameInDisplayPoints = nil
        self.onUpdate = onUpdate
        self.onLost = onLost
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        targetWindowIDs = []
        primaryWindowID = nil
        targetDisplayID = nil
        lastDisplayID = nil
        lastFrameInDisplayPoints = nil
        onUpdate = nil
        onLost = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await pollOnce()
        }
    }

    private func pollOnce() async {
        guard !targetWindowIDs.isEmpty else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            return
        }
        guard let primaryWindowID,
              let targetWindow = content.windows.first(where: { $0.windowID == primaryWindowID }),
              targetWindow.isOnScreen else {
            let lost = onLost
            stopMonitoring()
            lost?()
            return
        }

        let center = CGPoint(x: targetWindow.frame.midX, y: targetWindow.frame.midY)
        let displayID = RecordingWindowCoordinateSpace.displayID(containingCapturePoint: center)
            ?? targetDisplayID
        guard let displayID, NSScreen.screen(with: displayID) != nil else { return }
        targetDisplayID = displayID

        let frameInDisplayPoints = RecordingWindowCoordinateSpace.captureLocalFrame(
            forCaptureFrame: targetWindow.frame,
            displayID: displayID
        )
        guard lastDisplayID != displayID
                || lastFrameInDisplayPoints?.equalTo(frameInDisplayPoints) != true else {
            return
        }
        lastDisplayID = displayID
        lastFrameInDisplayPoints = frameInDisplayPoints
        onUpdate?(Update(
            displayID: displayID,
            frameInDisplayPoints: frameInDisplayPoints
        ))
    }
}
