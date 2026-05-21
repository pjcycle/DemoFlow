//
//  PiPOverlayWindowController.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import Foundation

final class PiPOverlayWindowController: NSObject, ObservableObject {
    private static let defaultPreviewSize = CGSize(width: 240, height: 240)

    @Published private(set) var layoutState: PiPLayoutState = .default
    @Published private(set) var isVisible = false

    var onVisibilityChanged: ((Bool) -> Void)?
    var onCloseRequested: (() -> Void)?
    var currentWindowID: CGWindowID? {
        guard let windowNumber = panel?.windowNumber, windowNumber > 0 else { return nil }
        return CGWindowID(windowNumber)
    }

    private var panel: PiPPanel?
    private var hostScreen: NSScreen?
    private var observers: [NotificationToken] = []
    private var windowConfig: PiPWindowConfig = .default
    private var runtimeTitleSuffix: String?
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    private var isApplyingProgrammaticFrame = false
    private var pendingLayoutSyncWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        configureFrontmostObservers()
    }

    deinit {
        pendingLayoutSyncWorkItem?.cancel()
        observers.forEach { observer in
            observer.center.removeObserver(observer.token)
        }
    }

    @discardableResult
    func show(session: AVCaptureSession, on screen: NSScreen, layout: PiPLayoutState) -> Bool {
        hostScreen = screen
        let normalizedLayout = resolvedLayout(layout, in: screen)
        layoutState = normalizedLayout
        print("[PiPWindow] show begin aspect=\(normalizedLayout.aspectRatio.rawValue) normalized=\(NSStringFromRect(normalizedLayout.normalizedRect)) visibleFrame=\(NSStringFromRect(screen.visibleFrame))")

        let panel = panel ?? makePanel(screen: screen)
        panel.screenProvider = { [weak self, weak panel] in
            panel?.screen ?? self?.hostScreen
        }
        panel.visibilityHandler = { [weak self] visible in
            self?.syncVisibility(visible)
        }
        panel.delegate = self
        applySizingConstraints(to: panel, aspectRatio: normalizedLayout.aspectRatio)
        let desiredFrame = frame(for: normalizedLayout, in: screen)
        let fittedFrame = clamped(frame: desiredFrame, in: screen.visibleFrame)
        print("[PiPWindow] frame desired=\(NSStringFromRect(desiredFrame)) fitted=\(NSStringFromRect(fittedFrame))")
        setFrame(fittedFrame, on: panel)

        if let previewView = panel.contentView as? PiPPreviewView {
            previewView.attach(session: session)
            previewView.applyTitleBarVisibility(windowConfig.isTitleBarVisible)
            previewView.applyFrameStyle(windowConfig.frameStyle)
            previewView.onScale = { [weak self] delta in
                self?.scaleWindow(by: delta)
            }
        }

        applyLevel(using: panel)
        panel.collectionBehavior = desiredCollectionBehavior
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        reassertFrontmost()
        let visibleNow = panel.isVisible
        print("[PiPWindow] orderFront complete visible=\(visibleNow) level=\(panel.level.rawValue) frame=\(NSStringFromRect(panel.frame))")
        if !visibleNow {
            reassertFrontmost(forceActivate: true)
        }
        scheduleFrontmostPasses()
        panel.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            print("[PiPWindow] post-show visible=\(panel.isVisible) key=\(panel.isKeyWindow) main=\(panel.isMainWindow) occlusion=\(panel.occlusionState.rawValue) frame=\(NSStringFromRect(panel.frame))")
            self.syncVisibility(panel.isVisible)
        }
        return true
    }

    func hide() {
        print("[PiPWindow] hide requested")
        syncLayoutFromWindow(immediately: true)
        panel?.orderOut(nil)
        syncVisibility(false)
    }

    func currentLayoutState() -> PiPLayoutState {
        let snapshot = currentLayoutSnapshot()
        return snapshot
    }

    func updateAspectRatio(_ aspectRatio: PiPAspectRatio) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.layoutState.aspectRatio != aspectRatio else { return }
            guard let panel = self.panel else { return }
            guard let screen = panel.screen ?? self.hostScreen else { return }

            let currentLayout = self.currentLayoutSnapshot()
            let nextRect = PiPGeometry.applyAspectSwitchKeepHeight(
                normalizedRect: currentLayout.normalizedRect,
                targetAspectRatio: aspectRatio,
                screenSize: screen.visibleFrame.size
            )
            let nextLayout = PiPLayoutState(
                normalizedRect: nextRect,
                aspectRatio: aspectRatio
            )
            self.layoutState = nextLayout
            self.applySizingConstraints(to: panel, aspectRatio: aspectRatio)
            let nextFrame = self.frame(for: nextLayout, in: screen)
            self.setFrame(self.clamped(frame: nextFrame, in: screen.visibleFrame), on: panel)
            self.syncLayoutFromWindow(immediately: true)
            if self.windowConfig.isAlwaysOnTop {
                self.orderFrontIfNeeded()
            }
        }
    }

    func updateProcessedPreviewImage(_ image: CGImage?) {
        guard let previewView = panel?.contentView as? PiPPreviewView else { return }
        previewView.updateProcessedImage(image)
    }

    func applyWindowConfig(_ config: PiPWindowConfig) {
        windowConfig = config
        guard let panel else { return }
        panel.title = resolvedWindowTitle()
        applyTitleBarVisibility(using: panel, isVisible: config.isTitleBarVisible)
        if let previewView = panel.contentView as? PiPPreviewView {
            previewView.applyTitleBarVisibility(config.isTitleBarVisible)
            previewView.applyFrameStyle(config.frameStyle)
        }
        applyLevel(using: panel)
        if panel.isVisible, config.isAlwaysOnTop {
            panel.orderFrontRegardless()
        }
    }

    func applyRuntimeWindowTitleSuffix(_ suffix: String?) {
        runtimeTitleSuffix = suffix
        panel?.title = resolvedWindowTitle()
    }

    private func configureFrontmostObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(
            NotificationToken(
                center: center,
                token: center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.orderFrontIfNeeded()
            }
            )
        )
        observers.append(
            NotificationToken(
                center: workspaceCenter,
                token: workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.orderFrontIfNeeded()
            }
            )
        )
        observers.append(
            NotificationToken(
                center: workspaceCenter,
                token: workspaceCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.orderFrontIfNeeded()
                }
            )
        )
    }

    private func orderFrontIfNeeded() {
        guard let panel else { return }
        guard panel.isVisible else { return }
        applyLevel(using: panel)
        panel.collectionBehavior = desiredCollectionBehavior
        guard windowConfig.isAlwaysOnTop else { return }
        reassertFrontmost()
    }

    private func reassertFrontmost(forceActivate: Bool = false) {
        guard let panel else { return }
        applyLevel(using: panel)
        panel.collectionBehavior = desiredCollectionBehavior
        guard windowConfig.isAlwaysOnTop || forceActivate else { return }
        if forceActivate {
            if #available(macOS 14.0, *) {
                NSRunningApplication.current.activate(options: [])
            } else {
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            }
        }
        panel.orderFrontRegardless()
    }

    private func scheduleFrontmostPasses() {
        DispatchQueue.main.async { [weak self] in
            self?.orderFrontIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.orderFrontIfNeeded()
        }
    }

    private func normalizeCurrentLayoutIfNeeded() {
        guard let panel else { return }
        guard let screen = panel.screen ?? hostScreen else { return }

        let fitted = clamped(frame: panel.frame, in: screen.visibleFrame)
        setFrame(fitted, on: panel)
        syncLayoutFromWindow(immediately: true)
    }

    private func resolvedLayout(_ layout: PiPLayoutState, in screen: NSScreen) -> PiPLayoutState {
        if panel == nil, layout == .default {
            return defaultSquareLayout(in: screen)
        }
        return PiPGeometry.normalizeLayout(layout, screenSize: screen.visibleFrame.size)
    }

    private func defaultSquareLayout(in screen: NSScreen) -> PiPLayoutState {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 1, visibleFrame.height > 1 else { return .default }

        let width = Self.defaultPreviewSize.width / visibleFrame.width
        let height = Self.defaultPreviewSize.height / visibleFrame.height
        let baseRect = PiPLayoutState.default.normalizedRect
        let centered = CGRect(
            x: baseRect.midX - width / 2.0,
            y: baseRect.midY - height / 2.0,
            width: width,
            height: height
        )
        return PiPLayoutState(
            normalizedRect: PiPGeometry.clampNormalized(centered),
            aspectRatio: .auto
        )
    }

    private func makePanel(screen: NSScreen) -> PiPPanel {
        let panel = PiPPanel(
            contentRect: frame(for: .default, in: screen),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        applyLevel(using: panel)
        panel.collectionBehavior = desiredCollectionBehavior
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.title = resolvedWindowTitle()
        applyTitleBarVisibility(using: panel, isVisible: windowConfig.isTitleBarVisible)
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .utilityWindow
        panel.onCloseRequested = { [weak self] in
            guard let self else { return }
            if let handler = self.onCloseRequested {
                handler()
            } else {
                self.hide()
            }
        }

        let content = PiPPreviewView(frame: panel.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        return panel
    }

    private func frame(for layout: PiPLayoutState, in screen: NSScreen) -> CGRect {
        let screenRect = screen.visibleFrame
        let normalized = PiPGeometry.normalizeLayout(layout, screenSize: screenRect.size).normalizedRect.standardized
        let width = normalized.width * screenRect.width
        let height = normalized.height * screenRect.height
        return CGRect(
            x: screenRect.minX + normalized.minX * screenRect.width,
            y: screenRect.minY + normalized.minY * screenRect.height,
            width: width,
            height: height
        )
    }

    private func currentLayoutSnapshot() -> PiPLayoutState {
        guard let panel else { return layoutState }
        guard let screen = panel.screen ?? hostScreen else { return layoutState }
        let frame = panel.frame
        let screenFrame = screen.visibleFrame
        guard screenFrame.width > 0, screenFrame.height > 0 else { return layoutState }

        let normalized = CGRect(
            x: (frame.minX - screenFrame.minX) / screenFrame.width,
            y: (frame.minY - screenFrame.minY) / screenFrame.height,
            width: frame.width / screenFrame.width,
            height: frame.height / screenFrame.height
        )
        return PiPLayoutState(
            normalizedRect: normalized,
            aspectRatio: layoutState.aspectRatio
        )
    }

    private func syncLayoutFromWindow(immediately: Bool = false) {
        guard !isApplyingProgrammaticFrame else { return }
        pendingLayoutSyncWorkItem?.cancel()
        let snapshot = currentLayoutSnapshot()
        guard snapshot != layoutState else { return }

        if immediately {
            layoutState = snapshot
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isApplyingProgrammaticFrame, self.layoutState != snapshot {
                self.layoutState = snapshot
            }
        }
        pendingLayoutSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func syncVisibility(_ visible: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isVisible != visible {
                self.isVisible = visible
            }
            print("[PiPWindow] visibility -> \(visible)")
            self.onVisibilityChanged?(visible)
        }
    }

    private func applyLevel(using panel: NSPanel) {
        panel.level = windowConfig.isAlwaysOnTop ? .mainMenu : .normal
    }

    private func applySizingConstraints(to panel: NSPanel, aspectRatio: PiPAspectRatio) {
        let size = minimumSize(for: aspectRatio)
        panel.contentMinSize = size
        panel.minSize = size
        panel.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        panel.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Avoid AppKit aspect-ratio property mutations during resize; we constrain
        // non-auto ratios in windowWillResize instead for better runtime stability.
    }

    private func applyTitleBarVisibility(using panel: NSPanel, isVisible: Bool) {
        if isVisible {
            panel.styleMask.insert(.titled)
            panel.styleMask.insert(.closable)
            panel.styleMask.insert(.miniaturizable)
            panel.styleMask.insert(.resizable)
            panel.styleMask.remove(.fullSizeContentView)
        } else {
            // Removing `.titled` avoids the 1px top hairline left by transparent titlebars.
            panel.styleMask.remove(.titled)
            panel.styleMask.remove(.closable)
            panel.styleMask.remove(.miniaturizable)
            panel.styleMask.insert(.resizable)
            panel.styleMask.insert(.fullSizeContentView)
        }
        panel.titleVisibility = isVisible ? .visible : .hidden
        panel.titlebarAppearsTransparent = !isVisible
        panel.backgroundColor = isVisible ? .windowBackgroundColor : .clear
        panel.isOpaque = isVisible
        panel.hasShadow = isVisible
        panel.standardWindowButton(.closeButton)?.isHidden = !isVisible
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = !isVisible
        panel.standardWindowButton(.zoomButton)?.isHidden = !isVisible
        if #available(macOS 11.0, *) {
            panel.titlebarSeparatorStyle = isVisible ? .automatic : .none
        }
        panel.isMovableByWindowBackground = !isVisible
        panel.invalidateShadow()
    }

    private func minimumSize(for aspectRatio: PiPAspectRatio) -> CGSize {
        guard aspectRatio != .auto else { return PiPLayoutState.minimumSize }

        let minimumWidth = max(
            PiPLayoutState.minimumSize.width,
            aspectRatio.width(forHeight: PiPLayoutState.minimumSize.height)
        )
        let minimumHeight = max(
            PiPLayoutState.minimumSize.height,
            aspectRatio.height(forWidth: minimumWidth)
        )
        return CGSize(width: minimumWidth, height: minimumHeight)
    }

    private func resolvedWindowTitle() -> String {
        let base = windowConfig.resolvedWindowTitle
        guard let runtimeTitleSuffix,
              !runtimeTitleSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return base + runtimeTitleSuffix
    }

    private func clamped(frame: CGRect, in bounds: CGRect) -> CGRect {
        var result = frame
        if result.width > bounds.width {
            result.size.width = bounds.width
        }
        if result.height > bounds.height {
            result.size.height = bounds.height
        }
        if result.minX < bounds.minX {
            result.origin.x = bounds.minX
        }
        if result.minY < bounds.minY {
            result.origin.y = bounds.minY
        }
        if result.maxX > bounds.maxX {
            result.origin.x = bounds.maxX - result.width
        }
        if result.maxY > bounds.maxY {
            result.origin.y = bounds.maxY - result.height
        }
        return result
    }

    private func scaleWindow(by delta: CGFloat) {
        guard let panel else { return }
        guard let screen = panel.screen ?? hostScreen else { return }
        let currentFrame = panel.frame
        let scaleFactor = pow(1.01, -delta)
        let minimumSize = minimumSize(for: layoutState.aspectRatio)
        let minWidth = minimumSize.width
        let minHeight = minimumSize.height
        let targetSize: CGSize
        if layoutState.aspectRatio == .auto {
            targetSize = CGSize(
                width: min(max(currentFrame.width * scaleFactor, minWidth), screen.visibleFrame.width),
                height: min(max(currentFrame.height * scaleFactor, minHeight), screen.visibleFrame.height)
            )
        } else {
            var targetWidth = min(max(currentFrame.width * scaleFactor, minWidth), screen.visibleFrame.width)
            var targetHeight = max(minHeight, layoutState.aspectRatio.height(forWidth: targetWidth))
            if targetHeight > screen.visibleFrame.height {
                targetHeight = screen.visibleFrame.height
                targetWidth = min(screen.visibleFrame.width, max(minWidth, layoutState.aspectRatio.width(forHeight: targetHeight)))
            }
            targetSize = CGSize(width: targetWidth, height: targetHeight)
        }
        let nextFrame = CGRect(
            x: currentFrame.midX - targetSize.width / 2.0,
            y: currentFrame.midY - targetSize.height / 2.0,
            width: targetSize.width,
            height: targetSize.height
        )
        setFrame(clamped(frame: nextFrame, in: screen.visibleFrame), on: panel)
        syncLayoutFromWindow(immediately: true)
    }

    private func setFrame(_ frame: CGRect, on panel: NSPanel) {
        guard !framesApproximatelyEqual(panel.frame, frame) else { return }
        isApplyingProgrammaticFrame = true
        panel.setFrame(frame, display: true, animate: false)
        isApplyingProgrammaticFrame = false
    }

    private func framesApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
        abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }
}

private struct NotificationToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

extension PiPOverlayWindowController: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard layoutState.aspectRatio != .auto else { return frameSize }

        let ratio = max(layoutState.aspectRatio.widthOverHeight, 0.01)
        let currentSize = sender.frame.size
        let widthDelta = abs(frameSize.width - currentSize.width)
        let heightDelta = abs(frameSize.height - currentSize.height)

        var adjustedFrameSize = frameSize
        if widthDelta >= heightDelta {
            adjustedFrameSize.height = adjustedFrameSize.width / ratio
        } else {
            adjustedFrameSize.width = adjustedFrameSize.height * ratio
        }

        let minimum = minimumSize(for: layoutState.aspectRatio)
        if adjustedFrameSize.width < minimum.width {
            adjustedFrameSize.width = minimum.width
            adjustedFrameSize.height = minimum.width / ratio
        }
        if adjustedFrameSize.height < minimum.height {
            adjustedFrameSize.height = minimum.height
            adjustedFrameSize.width = minimum.height * ratio
        }

        return adjustedFrameSize
    }

    func windowDidMove(_ notification: Notification) {
        // Avoid publishing layout while the user is dragging the window.
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        syncLayoutFromWindow(immediately: true)
    }

    func windowDidResize(_ notification: Notification) {
        // Avoid publishing layout during live resize; commit at the end instead.
    }

    func windowDidBecomeKey(_ notification: Notification) {
        orderFrontIfNeeded()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let panel = notification.object as? NSPanel {
            hostScreen = panel.screen ?? hostScreen
        }
        normalizeCurrentLayoutIfNeeded()
        orderFrontIfNeeded()
    }

    func windowDidBecomeVisible(_ notification: Notification) {
        if let panel = notification.object as? NSPanel {
            print("[PiPWindow] windowDidBecomeVisible frame=\(NSStringFromRect(panel.frame)) level=\(panel.level.rawValue)")
        }
        syncVisibility(true)
    }

    func windowWillClose(_ notification: Notification) {
        print("[PiPWindow] windowWillClose")
        syncLayoutFromWindow(immediately: true)
        syncVisibility(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        print("[PiPWindow] windowDidMiniaturize")
        syncVisibility(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        print("[PiPWindow] windowDidDeminiaturize")
        syncVisibility(true)
        orderFrontIfNeeded()
    }
}

private final class PiPPanel: NSPanel {
    var screenProvider: (() -> NSScreen?)?
    var onCloseRequested: (() -> Void)?
    var visibilityHandler: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        onCloseRequested?()
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        visibilityHandler?(false)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let target = screenProvider?() ?? screen
        guard let target else { return frameRect }
        var frame = frameRect
        let bounds = target.visibleFrame
        let minimumSize = CGSize(
            width: max(minSize.width, contentMinSize.width),
            height: max(minSize.height, contentMinSize.height)
        )
        if frame.width < minimumSize.width {
            frame.size.width = minimumSize.width
        }
        if frame.height < minimumSize.height {
            frame.size.height = minimumSize.height
        }
        if frame.minX < bounds.minX {
            frame.origin.x = bounds.minX
        }
        if frame.minY < bounds.minY {
            frame.origin.y = bounds.minY
        }
        if frame.maxX > bounds.maxX {
            frame.origin.x = bounds.maxX - frame.width
        }
        if frame.maxY > bounds.maxY {
            frame.origin.y = bounds.maxY - frame.height
        }
        return frame
    }
}

private final class PiPPreviewView: NSView {
    var onScale: ((CGFloat) -> Void)?

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var processedLayer: CALayer?
    private var frameStyle: PiPWindowFrameStyle = .circle
    private var isTitleBarVisible = true

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        processedLayer?.frame = bounds
        applyFrameShape()
    }

    func attach(session: AVCaptureSession) {
        ensureRootLayer()
        guard let rootLayer = layer else { return }
        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            rootLayer.addSublayer(layer)
            previewLayer = layer
        } else {
            previewLayer?.session = session
            if let previewLayer, previewLayer.superlayer == nil {
                rootLayer.addSublayer(previewLayer)
            }
        }

        if processedLayer == nil {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspectFill
            layer.isHidden = true
            rootLayer.addSublayer(layer)
            processedLayer = layer
        } else if let processedLayer, processedLayer.superlayer == nil {
            rootLayer.addSublayer(processedLayer)
        }

        applyTitleBarVisibility(true)
        applyFrameStyle(.circle)
        previewLayer?.frame = bounds
        processedLayer?.frame = bounds
    }

    func applyTitleBarVisibility(_ isTitleBarVisible: Bool) {
        self.isTitleBarVisible = isTitleBarVisible
        applyFrameShape()
    }

    func applyFrameStyle(_ style: PiPWindowFrameStyle) {
        frameStyle = style
        applyFrameShape()
    }

    func updateProcessedImage(_ image: CGImage?) {
        guard let processedLayer else { return }
        processedLayer.contents = image
        processedLayer.isHidden = image == nil
    }

    override func scrollWheel(with event: NSEvent) {
        onScale?(event.scrollingDeltaY)
    }

    private func ensureRootLayer() {
        if layer == nil {
            let root = CALayer()
            root.backgroundColor = NSColor.black.cgColor
            layer = root
            wantsLayer = true
            return
        }
        wantsLayer = true
    }

    private func applyFrameShape() {
        guard let rootLayer = layer else { return }
        let effectiveBounds = bounds
        guard effectiveBounds.width > 0, effectiveBounds.height > 0 else { return }

        rootLayer.masksToBounds = true
        rootLayer.borderWidth = 0
        rootLayer.borderColor = nil
        rootLayer.cornerCurve = .continuous
        rootLayer.mask = nil

        switch frameStyle {
        case .square:
            rootLayer.cornerRadius = 22
            if isTitleBarVisible {
                rootLayer.borderWidth = 1
                rootLayer.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            }
        case .circle:
            rootLayer.cornerRadius = min(effectiveBounds.width, effectiveBounds.height) / 2.0
        }

        rootLayer.backgroundColor = isTitleBarVisible ? NSColor.black.cgColor : NSColor.clear.cgColor
    }
}
