//
//  WindowTrackingService.swift
//  DemoFlow
//
//  2026-08-27 新增：窗口录制期间每 0.5s 轮询 SCShareableContent 跟踪目标窗口位置/尺寸；
//  窗口关闭/最小化/不在 onScreenWindowsOnly 时回调 onLost 让引擎触发自动停录。
//

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowTrackingService {
    struct Update {
        let displayID: CGDirectDisplayID
        let frameInDisplayPoints: CGRect
    }

    private var pollTask: Task<Void, Never>?
    private var targetWindowIDs: Set<CGWindowID> = []
    private var targetDisplayID: CGDirectDisplayID?
    private var lastFrameInDisplayPoints: CGRect = .zero
    private var onUpdate: ((Update) -> Void)?
    private var onLost: (() -> Void)?

    private let pollIntervalNanoseconds: UInt64 = 500_000_000

    var isTracking: Bool {
        pollTask != nil
    }

    func startTracking(
        windowIDs: [CGWindowID],
        displayID: CGDirectDisplayID,
        initialFrameInDisplayPoints: CGRect,
        onUpdate: @escaping (Update) -> Void,
        onLost: @escaping () -> Void
    ) {
        stopTracking()
        targetWindowIDs = Set(windowIDs)
        targetDisplayID = displayID
        lastFrameInDisplayPoints = initialFrameInDisplayPoints
        self.onUpdate = onUpdate
        self.onLost = onLost

        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopTracking() {
        pollTask?.cancel()
        pollTask = nil
        targetWindowIDs = []
        targetDisplayID = nil
        lastFrameInDisplayPoints = .zero
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
        guard !targetWindowIDs.isEmpty,
              let previousDisplayID = targetDisplayID else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            notifyLost()
            return
        }
        guard let targetWindow = content.windows.first(where: {
            $0.isOnScreen && targetWindowIDs.contains($0.windowID)
        }) else {
            notifyLost()
            return
        }
        let center = CGPoint(x: targetWindow.frame.midX, y: targetWindow.frame.midY)
        let displayID = RecordingWindowCoordinateSpace.displayID(containingCapturePoint: center)
            ?? previousDisplayID
        targetDisplayID = displayID
        guard NSScreen.screen(with: displayID) != nil else {
            notifyLost()
            return
        }
        let newFrame = RecordingWindowCoordinateSpace.captureLocalFrame(
            forCaptureFrame: targetWindow.frame,
            displayID: displayID
        )
        // frame 没变就不回调
        if newFrame.equalTo(lastFrameInDisplayPoints) { return }
        lastFrameInDisplayPoints = newFrame
        onUpdate?(Update(displayID: displayID, frameInDisplayPoints: newFrame))
    }

    private func notifyLost() {
        let lost = onLost
        stopTracking()
        lost?()
    }
}
