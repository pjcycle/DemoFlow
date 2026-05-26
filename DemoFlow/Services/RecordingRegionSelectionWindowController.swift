//
//  RecordingRegionSelectionWindowController.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/25.
//

import AppKit
import Foundation

@MainActor
final class RecordingRegionSelectionWindowController: NSObject {
    enum Result {
        case confirmed(RecordingRegionSelection)
        case cancelled
    }

    private var panel: RecordingRegionSelectionPanel?
    private var overlayView: RecordingRegionSelectionOverlayView?
    private var completion: ((Result) -> Void)?
    private var observers: [RecordingRegionNotificationToken] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var passThroughRefreshTimer: Timer?
    private var hostScreenID: CGDirectDisplayID?
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]
    private let overlayWindowLevel: NSWindow.Level = .floating

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var currentSelection: RecordingRegionSelection? {
        overlayView?.currentSelection
    }

    var onSelectionChanged: ((RecordingRegionSelection) -> Void)?

    override init() {
        super.init()
        configureObservers()
    }

    deinit {
        let globalMouseMonitor = self.globalMouseMonitor
        let localMouseMonitor = self.localMouseMonitor
        let observers = self.observers
        self.passThroughRefreshTimer?.invalidate()
        Task { @MainActor in
            if let globalMouseMonitor {
                NSEvent.removeMonitor(globalMouseMonitor)
            }
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
            }
            observers.forEach { observer in
                observer.center.removeObserver(observer.token)
            }
        }
    }

    @discardableResult
    func present(
        on screen: NSScreen?,
        initialSelection: RecordingRegionSelection?,
        completion: @escaping (Result) -> Void
    ) -> Bool {
        guard let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            completion(.cancelled)
            return false
        }
        guard let displayID = targetScreen.displayID else {
            completion(.cancelled)
            return false
        }

        dismiss(notify: false)
        self.completion = completion
        hostScreenID = displayID

        let panel = panel ?? makePanel(on: targetScreen)
        panel.collectionBehavior = desiredCollectionBehavior
        panel.level = overlayWindowLevel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        align(panel: panel, to: targetScreen)

        let displaySize = targetScreen.frame.size
        let candidateRect = initialSelection.flatMap { selection -> CGRect? in
            guard selection.displayID == displayID else { return nil }
            return selection.rectInDisplayPoints
        }

        overlayView?.prepare(
            displayID: displayID,
            displaySize: displaySize,
            initialRect: candidateRect
        )
        panel.ignoresMouseEvents = true
        self.panel = panel
        startMouseHitTestTracking()
        refreshOverlayHitTestState()

        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func confirmCurrentSelection() {
        guard let selection = overlayView?.currentSelection else {
            NSSound.beep()
            return
        }
        dismiss(notify: true, result: .confirmed(selection))
    }

    func cancelSelection() {
        dismiss(notify: true, result: .cancelled)
    }

    func dismiss(notify: Bool = false, result: Result = .cancelled) {
        stopMouseHitTestTracking()
        panel?.ignoresMouseEvents = false
        panel?.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        if notify {
            completion?(result)
        }
    }

    private func makePanel(on screen: NSScreen) -> RecordingRegionSelectionPanel {
        let panel = RecordingRegionSelectionPanel(
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
        panel.ignoresMouseEvents = true
        panel.level = overlayWindowLevel
        panel.collectionBehavior = desiredCollectionBehavior
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("recording-region-selection-window")
        panel.onCancelRequested = { [weak self] in
            self?.cancelSelection()
        }

        let overlay = RecordingRegionSelectionOverlayView(frame: panel.contentView?.bounds ?? .zero)
        overlay.autoresizingMask = [.width, .height]
        overlay.onSelectionChanged = { [weak self] selection in
            self?.onSelectionChanged?(selection)
        }
        panel.contentView = overlay
        panel.initialFirstResponder = overlay
        self.overlayView = overlay
        return panel
    }

    private func align(panel: NSPanel, to screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
    }

    private func configureObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(
            RecordingRegionNotificationToken(
                center: center,
                token: center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reassertFrontmost()
                    }
                }
            )
        )

        observers.append(
            RecordingRegionNotificationToken(
                center: workspaceCenter,
                token: workspaceCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reassertFrontmost()
                    }
                }
            )
        )

        observers.append(
            RecordingRegionNotificationToken(
                center: workspaceCenter,
                token: workspaceCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reassertFrontmost()
                    }
                }
            )
        )
    }

    private func reassertFrontmost() {
        guard let panel, panel.isVisible else { return }
        panel.level = overlayWindowLevel
        panel.collectionBehavior = desiredCollectionBehavior
        if let hostScreenID, let screen = NSScreen.screen(with: hostScreenID) {
            align(panel: panel, to: screen)
        }
        panel.orderFrontRegardless()
        refreshOverlayHitTestState()
    }

    private func startMouseHitTestTracking() {
        stopMouseHitTestTracking()

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp
        ]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOverlayHitTestState()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            self.refreshOverlayHitTestState()
            return event
        }

        passThroughRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOverlayHitTestState()
            }
        }
        if let passThroughRefreshTimer {
            RunLoop.main.add(passThroughRefreshTimer, forMode: .common)
        }
    }

    private func stopMouseHitTestTracking() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        passThroughRefreshTimer?.invalidate()
        passThroughRefreshTimer = nil
    }

    private func refreshOverlayHitTestState() {
        guard let panel,
              panel.isVisible,
              let overlayView else { return }

        let shouldCaptureMouse: Bool
        if overlayView.isDraggingSelection {
            shouldCaptureMouse = true
        } else {
            let location = panel.mouseLocationOutsideOfEventStream
            shouldCaptureMouse = overlayView.shouldCaptureMouse(at: location)
        }
        let shouldIgnoreMouse = !shouldCaptureMouse
        if panel.ignoresMouseEvents != shouldIgnoreMouse {
            panel.ignoresMouseEvents = shouldIgnoreMouse
        }
    }
}

private struct RecordingRegionNotificationToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

private final class RecordingRegionSelectionPanel: NSPanel {
    var onCancelRequested: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancelRequested?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancelRequested?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class RecordingRegionSelectionOverlayView: NSView {
    private let minSelectionSize = CGSize(width: 120, height: 120)
    private let initialSelectionSize = CGSize(width: 400, height: 400)
    private let interactionBandThickness: CGFloat = 30
    private let handleRadius: CGFloat = 5
    private let handleHotspotRadius: CGFloat = 12
    private let edgeHitThickness: CGFloat = 10

    private var displayID: CGDirectDisplayID?
    private var selectionRect: CGRect = .zero
    private var activeHandle: VideoCropHandle?
    private var dragStartRect: CGRect?
    private var dragStartPoint: CGPoint?
    var onSelectionChanged: ((RecordingRegionSelection) -> Void)?
    var isDraggingSelection: Bool {
        activeHandle != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentSelection: RecordingRegionSelection? {
        guard let displayID else { return nil }
        let normalizedRect = normalizedRect(from: selectionRect)
        guard normalizedRect.width > 0.01, normalizedRect.height > 0.01 else { return nil }
        return RecordingRegionSelection(
            displayID: displayID,
            rectInDisplayPoints: selectionRect.standardized
        )
    }

    func shouldCaptureMouse(at pointInWindow: CGPoint) -> Bool {
        let point = convert(pointInWindow, from: nil)
        return shouldHandleInteraction(at: point)
    }

    func prepare(
        displayID: CGDirectDisplayID,
        displaySize: CGSize,
        initialRect: CGRect?
    ) {
        self.displayID = displayID
        let candidate = initialRect ?? defaultRect(in: displaySize)
        selectionRect = clampedRect(candidate, in: displaySize)
        notifySelectionChangedIfNeeded()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let rect = clampedRect(selectionRect, in: bounds.size)
        selectionRect = rect

        let overlayPath = NSBezierPath(rect: bounds)
        overlayPath.appendRect(rect)
        overlayPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        overlayPath.fill()

        let dashedRect = rect.insetBy(dx: 1, dy: 1)
        let borderPath = NSBezierPath(rect: dashedRect)
        borderPath.lineWidth = 2
        borderPath.setLineDash([9, 7], count: 2, phase: 0)
        NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.0, alpha: 0.95).setStroke()
        borderPath.stroke()

        drawHandles(for: rect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let detectedHandle = handle(at: point)
        guard let detectedHandle else {
            activeHandle = nil
            dragStartRect = nil
            dragStartPoint = nil
            return
        }
        activeHandle = detectedHandle
        dragStartRect = selectionRect
        dragStartPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeHandle, let dragStartRect, let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: point.x - dragStartPoint.x,
            height: point.y - dragStartPoint.y
        )

        let startNormalized = normalizedRect(from: dragStartRect)
        let minNormalized = VideoCropGeometry.normalizeMinSize(
            minPoints: minSelectionSize,
            videoDisplaySize: bounds.size
        )
        let nextNormalized = VideoCropGeometry.applyDrag(
            startRect: startNormalized,
            translation: translation,
            handle: activeHandle,
            displaySize: bounds.size,
            lockedAspectRatio: nil,
            minSize: minNormalized
        )
        selectionRect = denormalizedRect(from: nextNormalized)
        notifySelectionChangedIfNeeded()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        activeHandle = nil
        dragStartRect = nil
        dragStartPoint = nil
    }

    private func defaultRect(in size: CGSize) -> CGRect {
        guard size.width > 1, size.height > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let width = min(max(minSelectionSize.width, initialSelectionSize.width), size.width)
        let height = min(max(minSelectionSize.height, initialSelectionSize.height), size.height)
        return clampedRect(
            CGRect(
                x: (size.width - width) / 2,
                y: (size.height - height) / 2,
                width: width,
                height: height
            ),
            in: size
        )
    }

    private func clampedRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 1, size.height > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let minWidth = min(minSelectionSize.width, size.width)
        let minHeight = min(minSelectionSize.height, size.height)

        var next = rect.standardized
        next.size.width = min(size.width, max(minWidth, next.width))
        next.size.height = min(size.height, max(minHeight, next.height))
        next.origin.x = max(0, min(next.origin.x, size.width - next.width))
        next.origin.y = max(0, min(next.origin.y, size.height - next.height))
        return next.integral
    }

    private func normalizedRect(from rect: CGRect) -> CGRect {
        guard bounds.width > 1, bounds.height > 1 else { return .zero }
        return CGRect(
            x: rect.origin.x / bounds.width,
            y: rect.origin.y / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        )
    }

    private func denormalizedRect(from normalizedRect: CGRect) -> CGRect {
        CGRect(
            x: normalizedRect.origin.x * bounds.width,
            y: normalizedRect.origin.y * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        )
    }

    private func drawHandles(for rect: CGRect) {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]

        for point in points {
            let handleRect = CGRect(
                x: point.x - handleRadius,
                y: point.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )
            let path = NSBezierPath(ovalIn: handleRect)
            NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.0, alpha: 1.0).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func handle(at point: CGPoint) -> VideoCropHandle? {
        guard selectionRect.width > 1, selectionRect.height > 1 else { return nil }
        guard shouldHandleInteraction(at: point) else { return nil }
        let rect = selectionRect

        let corners: [(VideoCropHandle, CGPoint)] = [
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.top, CGPoint(x: rect.midX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]

        var bestHandle: VideoCropHandle?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (handle, anchor) in corners {
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance <= handleHotspotRadius, distance < bestDistance {
                bestDistance = distance
                bestHandle = handle
            }
        }
        if let bestHandle {
            return bestHandle
        }

        if abs(point.x - rect.minX) <= edgeHitThickness, point.y >= rect.minY, point.y <= rect.maxY {
            return .left
        }
        if abs(point.x - rect.maxX) <= edgeHitThickness, point.y >= rect.minY, point.y <= rect.maxY {
            return .right
        }
        if abs(point.y - rect.minY) <= edgeHitThickness, point.x >= rect.minX, point.x <= rect.maxX {
            return .bottom
        }
        if abs(point.y - rect.maxY) <= edgeHitThickness, point.x >= rect.minX, point.x <= rect.maxX {
            return .top
        }
        return .move
    }

    private func shouldHandleInteraction(at point: CGPoint) -> Bool {
        let rect = selectionRect.standardized
        guard rect.width > 1, rect.height > 1 else { return false }
        if rect.contains(point) {
            return true
        }
        return isPointInInteractiveBand(point)
    }

    private func isPointInInteractiveBand(_ point: CGPoint) -> Bool {
        let rect = selectionRect.standardized
        guard rect.width > 1, rect.height > 1 else { return false }

        let expanded = rect.insetBy(dx: -interactionBandThickness, dy: -interactionBandThickness)
        guard expanded.contains(point) else { return false }

        let innerRect = rect.insetBy(dx: interactionBandThickness, dy: interactionBandThickness)
        if innerRect.isNull || innerRect.isEmpty {
            return true
        }
        return !innerRect.contains(point)
    }

    private func notifySelectionChangedIfNeeded() {
        guard let selection = currentSelection else { return }
        onSelectionChanged?(selection)
    }
}
