//
//  RecordingWindowSelectionWindowController.swift
//  DemoFlow
//
//  2026-08-27 新增：窗口录制模式下让用户点选目标窗口。
//  设计：全屏透明覆盖面板 + crosshair 光标 + 命中 SCShareableContent 中的窗口 +
//  实时虚线高亮 + 鼠标松开确认 / ESC 取消。
//

import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class RecordingWindowSelectionWindowController: NSObject {
    enum Result {
        case confirmed(RecordingWindowSelection)
        case cancelled
    }

    private var panels: [RecordingWindowSelectionPanel] = []
    private var overlayViews: [RecordingWindowSelectionOverlayView] = []
    private var completion: ((Result) -> Void)?
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var localKeyMonitor: Any?
    private var pendingScreenFrames: [CGRect] = []
    private var shareableContent: SCShareableContent?
    private var pendingWindowID: CGWindowID?
    private var pendingDisplayID: CGDirectDisplayID?
    private var pendingFrameInDisplayPoints: CGRect?

    private var continuousWindowPicked: ((RecordingWindowSelection) -> Void)?
    private var continuousWindowFrameUpdated: ((RecordingWindowSelection) -> Void)?
    private var continuousWindowDeselected: (() -> Void)?
    private var continuousEscape: (() -> Void)?
    private var continuousWindowLost: (() -> Void)?
    private var isContinuousListening = false
    private var isPreparingContinuousListening = false
    private var continuousListeningGeneration = 0
    private var continuousMouseUpMonitor: Any?
    private var continuousKeyMonitor: Any?
    private let selectedWindowValidityMonitor = SelectedWindowValidityMonitor()
    private var selectedOwnerBundleID: String?
    private var selectedWindowID: CGWindowID?
    private var highlightedSelection: RecordingWindowSelection?

    private static let excludedSystemBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight"
    ]

    var isVisible: Bool {
        !panels.isEmpty
    }

    var isListening: Bool {
        isContinuousListening || isPreparingContinuousListening
    }

    override init() {
        super.init()
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.dismiss(notify: false)
        }
    }

    @discardableResult
    func present(completion: @escaping (Result) -> Void) -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(.cancelled)
            return false
        }

        dismiss(notify: false)
        self.completion = completion
        pendingScreenFrames = screens.map { $0.frame }

        installPanels(on: screens)
        installMonitors()
        primeShareableContent()

        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func cancelSelection() {
        dismiss(notify: true, result: .cancelled)
    }

    /// 持续监听模式：先 await 准备好 SCShareableContent，再装全局 mouseUp monitor + ESC 监听；
    /// 不弹 modal panel。鼠标点中任一窗口立即回调 onWindowPicked，ESC 触发 onEscape。
    /// 调用方负责在适当时候调用 stopContinuousListening 关闭。
    func startContinuousListening(
        onWindowPicked: @escaping (RecordingWindowSelection) -> Void,
        onWindowFrameUpdated: @escaping (RecordingWindowSelection) -> Void,
        onWindowDeselected: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onWindowLost: @escaping () -> Void
    ) async {
        stopContinuousListening()
        let generation = continuousListeningGeneration
        isPreparingContinuousListening = true
        // 先准备好 shareableContent，否则首次 mouseUp 时 pendingWindowID = nil 会命中失败
        await primeShareableContentAsync()
        guard generation == continuousListeningGeneration,
              !Task.isCancelled else {
            isPreparingContinuousListening = false
            return
        }
        isPreparingContinuousListening = false
        continuousWindowPicked = onWindowPicked
        continuousWindowFrameUpdated = onWindowFrameUpdated
        continuousWindowDeselected = onWindowDeselected
        continuousEscape = onEscape
        continuousWindowLost = onWindowLost
        isContinuousListening = true
        installContinuousMonitors()
    }

    private func primeShareableContentAsync() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            self.shareableContent = content
        } catch {
            self.shareableContent = nil
        }
    }

    func stopContinuousListening(keepingHighlight: Bool = false) {
        continuousListeningGeneration += 1
        isPreparingContinuousListening = false
        removeContinuousMonitors()
        continuousWindowPicked = nil
        continuousWindowFrameUpdated = nil
        continuousWindowDeselected = nil
        continuousEscape = nil
        continuousWindowLost = nil
        isContinuousListening = false
        if !keepingHighlight {
            dismissHighlight()
            selectedOwnerBundleID = nil
            selectedWindowID = nil
            highlightedSelection = nil
        }
    }

    /// 清除当前选中窗口，但保留连续监听，供准备态下重新选择或取消当前选择。
    func clearCurrentSelection() {
        pendingWindowID = nil
        pendingDisplayID = nil
        pendingFrameInDisplayPoints = nil
        selectedOwnerBundleID = nil
        selectedWindowID = nil
        highlightedSelection = nil
        dismissHighlight()
    }

    /// 仅在目标窗口所在屏装一个透明 panel（不拦鼠标）并画虚线高亮；
    /// 不在其它屏装 panel 避免误画导致"覆盖全屏"视觉问题。
    func presentHighlight(for selection: RecordingWindowSelection) {
        selectedOwnerBundleID = selection.ownerBundleID
        selectedWindowID = selection.windowID
        highlightedSelection = selection
        dismissHighlight()
        guard let targetScreen = NSScreen.screen(with: selection.displayID) else { return }
        let screenFrame = targetScreen.frame

        let panel = RecordingWindowSelectionPanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        // 高亮只负责显示，不应压住录屏控制条。
        // 控制条使用 statusBar 层，这里使用 floating 层确保它始终可点击。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("recording-window-highlight-panel")

        let overlay = RecordingWindowSelectionOverlayView(frame: panel.contentView?.bounds ?? .zero)
        overlay.autoresizingMask = [.width, .height]
        panel.contentView = overlay
        overlayViews.append(overlay)
        panels.append(panel)
        pendingScreenFrames.append(screenFrame)
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()

        // frameInDisplayPoints 已是屏幕本地坐标；overlay 的 bounds 也以该屏原点为 (0, 0)。
        overlay.applyHighlight(
            rect: RecordingWindowCoordinateSpace.cocoaLocalFrame(
                forCaptureLocalFrame: selection.frameInDisplayPoints,
                in: targetScreen
            ),
            windowID: selection.windowID
        )

        // 实时监测选中窗口的尺寸/位置；关闭或最小化时清除选择。
        selectedWindowValidityMonitor.startMonitoring(
            windowIDs: selection.windowIDs,
            displayID: selection.displayID,
            onUpdate: { [weak self] update in
                self?.updateHighlightedFrame(update)
            },
            onLost: { [weak self] in
                guard let self else { return }
                self.clearCurrentSelection()
                self.continuousWindowLost?()
            }
        )
    }

    func dismissHighlight() {
        selectedWindowValidityMonitor.stopMonitoring()
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        overlayViews.removeAll()
        pendingScreenFrames.removeAll()
    }

    func dismiss(notify: Bool = false, result: Result = .cancelled) {
        removeMonitors()
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        overlayViews.removeAll()
        pendingScreenFrames.removeAll()
        pendingWindowID = nil
        pendingDisplayID = nil
        pendingFrameInDisplayPoints = nil
        shareableContent = nil

        let completion = self.completion
        self.completion = nil
        if notify {
            completion?(result)
        }
    }

    // MARK: - Panels

    private func installPanels(on screens: [NSScreen]) {
        for screen in screens {
            let panel = RecordingWindowSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isMovableByWindowBackground = false
            panel.isFloatingPanel = true
            panel.ignoresMouseEvents = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.tabbingMode = .disallowed
            panel.isReleasedWhenClosed = false
            panel.identifier = NSUserInterfaceItemIdentifier("recording-window-selection-panel")
            panel.onEscapePressed = { [weak self] in
                self?.cancelSelection()
            }

            let overlay = RecordingWindowSelectionOverlayView(frame: panel.contentView?.bounds ?? .zero)
            overlay.autoresizingMask = [.width, .height]
            panel.contentView = overlay
            panel.initialFirstResponder = overlay
            overlayViews.append(overlay)
            panels.append(panel)

            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Monitors

    private func installMonitors() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseDown(at: NSEvent.mouseLocation, event: event)
            }
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseUp(at: NSEvent.mouseLocation, event: event)
            }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseMoved(to: NSEvent.mouseLocation)
            }
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // ESC
                Task { @MainActor [weak self] in
                    self?.cancelSelection()
                }
                return nil
            }
            return event
        }
        NSCursor.crosshair.push()
    }

    private func installContinuousMonitors() {
        // 在 mouseDown 时预先计算候选窗口（不用拦截事件，让点击自然传递到目标窗口）
        continuousMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                if event.type == .leftMouseDown {
                    self?.handleMouseDown(at: NSEvent.mouseLocation, event: event)
                } else {
                    self?.handleMouseUp(at: NSEvent.mouseLocation, event: event)
                }
            }
        }
        continuousKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // ESC
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.continuousEscape?()
            }
        }
    }

    private func removeContinuousMonitors() {
        if let monitor = continuousMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            continuousMouseUpMonitor = nil
        }
        if let monitor = continuousKeyMonitor {
            NSEvent.removeMonitor(monitor)
            continuousKeyMonitor = nil
        }
    }

    private func removeMonitors() {
        if let monitor = globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseDownMonitor = nil
        }
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
        if let monitor = localMouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMoveMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        NSCursor.pop()
    }

    // MARK: - ShareableContent

    private func primeShareableContent() {
        Task { @MainActor [weak self] in
            do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
                self?.shareableContent = content
            } catch {
                self?.shareableContent = nil
            }
        }
    }

    // MARK: - Mouse handlers

    private func handleMouseMoved(to cocoaLocation: NSPoint) {
        updateHighlight(forCocoaLocation: cocoaLocation)
    }

    private func handleMouseDown(at cocoaLocation: NSPoint, event: NSEvent) {
        // 鼠标按下仅记录不触发确认；让用户能拖出选区再做确认
        // 但窗口选择不需要拖选，这里 mouseDown 仅用于吃掉事件避免穿透到目标窗口
        // 真正的确认在 mouseUp
        updateHighlight(forCocoaLocation: cocoaLocation)
    }

    private func handleMouseUp(at cocoaLocation: NSPoint, event: NSEvent) {
        let pickedWindowID = pendingWindowID
        let pickedDisplayID = pendingDisplayID
        var pickedFrame = pendingFrameInDisplayPoints
        // clear pending 以便下一次命中能正确触发
        pendingWindowID = nil
        pendingDisplayID = nil
        pendingFrameInDisplayPoints = nil

        // mouseUp 时再查一次 SCShareableContent 取最新 frame（覆盖 mouseDown→mouseUp 间窗口移动）
        if let windowID = pickedWindowID,
           let content = shareableContent,
           let latest = content.windows.first(where: { $0.windowID == windowID }),
           let displayID = pickedDisplayID {
            pickedFrame = RecordingWindowCoordinateSpace.captureLocalFrame(
                forCaptureFrame: latest.frame,
                displayID: displayID
            )
        }

        guard let windowID = pickedWindowID,
              let displayID = pickedDisplayID,
              let frameInDisplayPoints = pickedFrame else {
            // 没有命中任何窗口
            if isContinuousListening {
                // continuous 模式下点空白处不退出；只忽略这次点击
                return
            }
            dismiss(notify: true, result: .cancelled)
            return
        }
        let content = shareableContent
        let pickedWindow = content?.windows.first(where: { $0.windowID == windowID })
        let owningApp = pickedWindow?.owningApplication
        let bundleID = owningApp?.bundleIdentifier

        // Toggle 行为：再点同一个应用（或 owningApplication 缺失时的同一窗口）
        // 取消选中并清除虚线框。
        let isSameSelectedTarget = windowID == selectedWindowID
            || (selectedWindowID == nil
                && bundleID != nil
                && bundleID == selectedOwnerBundleID)
        if isContinuousListening, isSameSelectedTarget {
            clearCurrentSelection()
            continuousWindowDeselected?()
            return
        }
        selectedOwnerBundleID = bundleID
        selectedWindowID = windowID

        let title = owningApp?.applicationName ?? pickedWindow?.title ?? ""
        let selectedApplicationWindows: [SCWindow] = {
            guard let bundleID, let content else {
                return pickedWindow.map { [$0] } ?? []
            }
            let windows = content.windows.filter { window in
                guard window.isOnScreen,
                      window.owningApplication?.bundleIdentifier == bundleID else {
                    return false
                }
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                return RecordingWindowCoordinateSpace.displayID(containingCapturePoint: center) == displayID
            }
            return windows.isEmpty ? (pickedWindow.map { [$0] } ?? []) : windows
        }()
        let selectedWindowIDs = selectedApplicationWindows.map(\.windowID)
        let selectedFrames = selectedApplicationWindows.map {
            RecordingWindowCoordinateSpace.captureLocalFrame(
                forCaptureFrame: $0.frame,
                displayID: displayID
            )
        }
        let selectedFrame = selectedFrames.dropFirst().reduce(
            selectedFrames.first ?? frameInDisplayPoints
        ) { $0.union($1) }
        let selection = RecordingWindowSelection(
            windowID: windowID,
            windowIDs: selectedWindowIDs.contains(windowID)
                ? selectedWindowIDs
                : [windowID] + selectedWindowIDs,
            displayID: displayID,
            frameInDisplayPoints: selectedFrame,
            ownerBundleID: bundleID,
            title: String(title.prefix(64))
        )
        if isContinuousListening {
            continuousWindowPicked?(selection)
            return
        }
        dismiss(notify: true, result: .confirmed(selection))
    }

    private func updateHighlight(forCocoaLocation cocoaLocation: NSPoint) {
        guard let content = shareableContent else {
            applyHighlight(windowID: nil, frameInDisplayPoints: nil, displayID: nil)
            return
        }
        // 先用 Quartz 的前后顺序确定真正位于鼠标下方的窗口，避免命中 Dock/桌面辅助窗口。
        let captureLocation = RecordingWindowCoordinateSpace.capturePoint(
            forCocoaPoint: CGPoint(x: cocoaLocation.x, y: cocoaLocation.y)
        )
        let topWindow = topApplicationWindow(
            at: captureLocation,
            content: content
        )

        if let topWindow {
            // 找到窗口所在 display
            if let displayID = RecordingWindowCoordinateSpace.displayID(
                containingCapturePoint: captureLocation
            ) {
                let frameInDisplayPoints = RecordingWindowCoordinateSpace.captureLocalFrame(
                    forCaptureFrame: topWindow.frame,
                    displayID: displayID
                )
                pendingWindowID = topWindow.windowID
                pendingDisplayID = displayID
                pendingFrameInDisplayPoints = frameInDisplayPoints
                applyHighlight(
                    windowID: topWindow.windowID,
                    frameInDisplayPoints: frameInDisplayPoints,
                    displayID: displayID
                )
            } else {
                pendingWindowID = nil
                pendingDisplayID = nil
                pendingFrameInDisplayPoints = nil
                applyHighlight(windowID: nil, frameInDisplayPoints: nil, displayID: nil)
            }
        } else {
            pendingWindowID = nil
            pendingDisplayID = nil
            pendingFrameInDisplayPoints = nil
            applyHighlight(windowID: nil, frameInDisplayPoints: nil, displayID: nil)
        }
    }

    private func updateHighlightedFrame(_ update: SelectedWindowValidityMonitor.Update) {
        guard var selection = highlightedSelection,
              selection.windowID == selectedWindowID else { return }

        selection = RecordingWindowSelection(
            windowID: selection.windowID,
            windowIDs: selection.windowIDs,
            displayID: update.displayID,
            frameInDisplayPoints: update.frameInDisplayPoints,
            ownerBundleID: selection.ownerBundleID,
            title: selection.title
        )
        highlightedSelection = selection

        guard let targetScreen = NSScreen.screen(with: update.displayID),
              let overlay = overlayViews.last,
              let panel = overlay.window as? NSPanel else { return }
        let screenFrame = targetScreen.frame
        if !panel.frame.equalTo(screenFrame) {
            // 窗口跨屏时，旧面板的坐标系已经失效，重建到新屏。
            continuousWindowFrameUpdated?(selection)
            presentHighlight(for: selection)
            return
        }
        overlay.applyHighlight(
            rect: RecordingWindowCoordinateSpace.cocoaLocalFrame(
                forCaptureLocalFrame: update.frameInDisplayPoints,
                in: targetScreen
            ),
            windowID: selection.windowID
        )
        continuousWindowFrameUpdated?(selection)
    }

    private func topApplicationWindow(
        at captureLocation: CGPoint,
        content: SCShareableContent
    ) -> SCWindow? {
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let valid: (SCWindow) -> Bool = { window in
            guard window.isOnScreen,
                  window.windowID != 0,
                  window.windowLayer == 0,
                  window.frame.width >= 40,
                  window.frame.height >= 40,
                  let application = window.owningApplication else {
                return false
            }
            // 选择层自身是一个全屏透明窗口，也会出现在 SCShareableContent 中。
            // 如果不排除它，鼠标命中时会把整块屏幕误认为目标窗口。
            guard application.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return false
            }
            return !Self.excludedSystemBundleIDs.contains(application.bundleIdentifier)
        }

        if let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            for info in infoList {
                guard let number = info[kCGWindowNumber as String] as? NSNumber,
                      let window = windowsByID[CGWindowID(number.uint32Value)],
                      valid(window),
                      let bounds = quartzWindowBounds(from: info),
                      bounds.contains(captureLocation) else {
                    continue
                }
                return window
            }
        }

        return content.windows
            .filter { valid($0) && $0.frame.contains(captureLocation) }
            .max { lhs, rhs in lhs.windowLayer < rhs.windowLayer }
    }

    private func quartzWindowBounds(from info: [String: Any]) -> CGRect? {
        guard let values = info[kCGWindowBounds as String] as? [String: Any],
              let x = (values["X"] as? NSNumber)?.doubleValue,
              let y = (values["Y"] as? NSNumber)?.doubleValue,
              let width = (values["Width"] as? NSNumber)?.doubleValue,
              let height = (values["Height"] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func applyHighlight(
        windowID: CGWindowID?,
        frameInDisplayPoints: CGRect?,
        displayID: CGDirectDisplayID?
    ) {
        for overlay in overlayViews {
            if let windowID, let frameInDisplayPoints, let displayID,
               let panel = overlay.window as? NSPanel,
               let screen = NSScreen.screen(with: displayID),
               let panelScreenFrame = pendingScreenFrame(forPanel: panel),
               panelScreenFrame.equalTo(screen.frame) {
                overlay.applyHighlight(
                    rect: RecordingWindowCoordinateSpace.cocoaLocalFrame(
                        forCaptureLocalFrame: frameInDisplayPoints,
                        in: screen
                    ),
                    windowID: windowID
                )
            } else {
                overlay.applyHighlight(rect: nil, windowID: nil)
            }
        }
    }

    private func pendingScreenFrame(forPanel panel: NSPanel) -> CGRect? {
        pendingScreenFrames.first(where: { $0.equalTo(panel.frame) })
    }
}

private final class RecordingWindowSelectionPanel: NSPanel {
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
}

private final class RecordingWindowSelectionOverlayView: NSView {
    private var highlightRect: CGRect?
    private var highlightedWindowID: CGWindowID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyHighlight(rect: CGRect?, windowID: CGWindowID?) {
        highlightRect = rect
        highlightedWindowID = windowID
        needsDisplay = true
    }

    /// 与 RecordingRegionSelectionOverlayView 视觉对齐：
    /// 屏幕半透明遮罩 + 选中区域挖空 + 浅蓝虚线边框 [9, 7]
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let highlightRect, highlightRect.width > 1, highlightRect.height > 1 else {
            return
        }

        // 半透明黑色遮罩 + 选中区域挖空（evenOdd）
        let overlayPath = NSBezierPath(rect: bounds)
        overlayPath.appendRect(highlightRect)
        overlayPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        overlayPath.fill()

        // 浅蓝虚线边框 [9, 7]
        let dashedRect = highlightRect.insetBy(dx: 1, dy: 1)
        let borderPath = NSBezierPath(rect: dashedRect)
        borderPath.lineWidth = 2
        borderPath.setLineDash([9, 7], count: 2, phase: 0)
        NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.0, alpha: 0.95).setStroke()
        borderPath.stroke()
    }
}
