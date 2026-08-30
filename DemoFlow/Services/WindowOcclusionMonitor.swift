//
//  WindowOcclusionMonitor.swift
//  DemoFlow
//
//  2026-08-27 新增：窗口录制期间每 1s 检测目标窗口是否被其他窗口覆盖；
//  仅触发回调通知（不停止录制），UI 层负责展示一次 5s 自动消失的 toast。
//

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowOcclusionMonitor {
    private var pollTask: Task<Void, Never>?
    private var targetWindowID: CGWindowID?
    private var hasNotifiedOcclusion = false
    private var onOccluded: (() -> Void)?
    private var onUnoccluded: (() -> Void)?

    private let pollIntervalNanoseconds: UInt64 = 1_000_000_000

    var isMonitoring: Bool {
        pollTask != nil
    }

    func startMonitoring(
        windowID: CGWindowID,
        onOccluded: @escaping () -> Void,
        onUnoccluded: @escaping () -> Void
    ) {
        stopMonitoring()
        targetWindowID = windowID
        hasNotifiedOcclusion = false
        self.onOccluded = onOccluded
        self.onUnoccluded = onUnoccluded

        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        targetWindowID = nil
        hasNotifiedOcclusion = false
        onOccluded = nil
        onUnoccluded = nil
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
        guard let windowID = targetWindowID else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return
        }
        guard let target = content.windows.first(where: { $0.windowID == windowID }),
              target.isOnScreen else {
            return
        }
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        // 找覆盖中心点且 layer 最大的窗口
        let covering = content.windows.filter { window in
            guard window.isOnScreen, window.windowID != windowID else { return false }
            return window.frame.contains(center)
        }
        let topCovering = covering.max { lhs, rhs in
            lhs.windowLayer < rhs.windowLayer
        }
        if topCovering != nil {
            if !hasNotifiedOcclusion {
                hasNotifiedOcclusion = true
                onOccluded?()
            }
        } else {
            if hasNotifiedOcclusion {
                hasNotifiedOcclusion = false
                onUnoccluded?()
            }
        }
    }
}