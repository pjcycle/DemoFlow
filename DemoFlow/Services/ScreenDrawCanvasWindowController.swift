//
//  ScreenDrawCanvasWindowController.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import AppKit
import Combine
import Foundation
import QuartzCore

@MainActor
final class ScreenDrawCanvasWindowController: NSObject {
    enum ScreenRecoveryEvent {
        case switchedToFallbackMainScreen
        case switchedToFallbackFirstScreen
        case noAvailableScreen
        case frameRecomputedAfterScreenChange
    }

    private var panel: ScreenDrawCanvasPanel?
    private var hostScreen: NSScreen?
    private var hostScreenID: CGDirectDisplayID?
    private var lastResolvedScreenID: CGDirectDisplayID?
    private var observers: [CanvasNotificationToken] = []
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]
    private let sessionStore: ScreenDrawSessionStore
    private var isCanvasMouseTransparent = false
    private var dismissalCompletionTask: Task<Void, Never>?

    var onVisibilityChanged: ((Bool) -> Void)?
    var onScreenRecoveryEvent: ((ScreenRecoveryEvent) -> Void)?
    var onRequestClose: (() -> Void)?

    init(sessionStore: ScreenDrawSessionStore) {
        self.sessionStore = sessionStore
        super.init()
        configureObservers()
    }

    deinit {
        let observers = self.observers
        Task { @MainActor in
            observers.forEach { observer in
                observer.center.removeObserver(observer.token)
            }
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var currentWindowID: CGWindowID? {
        guard let windowNumber = panel?.windowNumber, windowNumber > 0 else { return nil }
        return CGWindowID(windowNumber)
    }

    var drawSessionStore: ScreenDrawSessionStore {
        sessionStore
    }

    var isCanvasInteractionEnabled: Bool {
        !isCanvasMouseTransparent
    }

    var hasDrawableContent: Bool {
        sessionStore.hasDrawableContent
    }

    var currentScreen: NSScreen? {
        hostScreen
            ?? panel?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    @discardableResult
    func show(on screen: NSScreen?) -> Bool {
        let targetScreen = screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else {
            onScreenRecoveryEvent?(.noAvailableScreen)
            onVisibilityChanged?(false)
            return false
        }

        let panel = panel ?? makePanel(on: targetScreen)
        align(panel: panel, to: targetScreen)
        panel.collectionBehavior = desiredCollectionBehavior
        panel.level = .mainMenu
        panel.ignoresMouseEvents = isCanvasMouseTransparent
        panel.orderFrontRegardless()
        self.panel = panel
        let visible = panel.isVisible
        onVisibilityChanged?(visible)
        return visible
    }

    func hide() {
        dismissalCompletionTask?.cancel()
        dismissalCompletionTask = nil
        sessionStore.cancelActivePointerInteraction()
        panel?.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func hideWithDismissalAnimation(completion: (() -> Void)? = nil) {
        guard isVisible else {
            completion?()
            return
        }
        guard sessionStore.hasDrawableContent else {
            hide()
            completion?()
            return
        }

        guard sessionStore.beginDismissalAnimation() != nil else {
            hide()
            completion?()
            return
        }

        panel?.ignoresMouseEvents = true
        let duration = ScreenDrawDismissalAnimationConstants.duration
        dismissalCompletionTask?.cancel()
        dismissalCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            self.sessionStore.completeDismissalAnimation(clearCanvas: true)
            self.panel?.ignoresMouseEvents = self.isCanvasMouseTransparent
            self.hide()
            completion?()
        }
    }

    func clearCanvasWithDismissalAnimation(completion: (() -> Void)? = nil) {
        guard isVisible else {
            sessionStore.clearCanvas()
            completion?()
            return
        }
        guard sessionStore.hasDrawableContent else {
            sessionStore.clearCanvas()
            completion?()
            return
        }

        guard sessionStore.beginDismissalAnimation() != nil else {
            completion?()
            return
        }

        panel?.ignoresMouseEvents = true
        let duration = ScreenDrawDismissalAnimationConstants.duration
        dismissalCompletionTask?.cancel()
        dismissalCompletionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            self.sessionStore.completeDismissalAnimation(clearCanvas: true)
            self.panel?.ignoresMouseEvents = self.isCanvasMouseTransparent
            completion?()
        }
    }

    func setCanvasInteractionEnabled(_ enabled: Bool) {
        isCanvasMouseTransparent = !enabled
        if sessionStore.isDismissingWithAnimation {
            panel?.ignoresMouseEvents = true
        } else {
            panel?.ignoresMouseEvents = !enabled
        }
    }

    func snapshotImage() -> NSImage? {
        guard let view = panel?.contentView as? ScreenDrawCanvasView else {
            return nil
        }
        return view.exportSnapshotImage()
    }

    private func makePanel(on screen: NSScreen) -> ScreenDrawCanvasPanel {
        let panel = ScreenDrawCanvasPanel(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.tr("legacy.key_77")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.level = .mainMenu
        panel.collectionBehavior = desiredCollectionBehavior
        panel.animationBehavior = .none
        panel.onCloseRequested = { [weak self] in
            guard let self else { return }
            if let onRequestClose {
                onRequestClose()
            } else {
                self.hide()
            }
        }
        panel.visibilityHandler = { [weak self] visible in
            self?.onVisibilityChanged?(visible)
        }

        let contentView = ScreenDrawCanvasView(sessionStore: sessionStore)
        contentView.frame = panel.contentView?.bounds ?? .zero
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        return panel
    }

    private func configureObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(
            CanvasNotificationToken(
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
            CanvasNotificationToken(
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
            CanvasNotificationToken(
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

        observers.append(
            CanvasNotificationToken(
                center: center,
                token: center.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshFrameForCurrentScreen(reason: .frameRecomputedAfterScreenChange)
                    }
                }
            )
        )
    }

    private func reassertFrontmost() {
        guard let panel, panel.isVisible else { return }
        panel.level = .mainMenu
        panel.collectionBehavior = desiredCollectionBehavior
        panel.ignoresMouseEvents = sessionStore.isDismissingWithAnimation ? true : isCanvasMouseTransparent
        refreshFrameForCurrentScreen()
        panel.orderFrontRegardless()
    }

    private func refreshFrameForCurrentScreen(reason: ScreenRecoveryEvent? = nil) {
        guard let panel, panel.isVisible else { return }
        let targetScreen = resolvedScreen()
        guard let targetScreen else {
            onScreenRecoveryEvent?(.noAvailableScreen)
            return
        }
        align(panel: panel, to: targetScreen)
        if let reason {
            onScreenRecoveryEvent?(reason)
        }
    }

    private func resolvedScreen() -> NSScreen? {
        if let hostScreenID {
            if let matched = matchScreen(by: hostScreenID) {
                lastResolvedScreenID = hostScreenID
                return matched
            }
        } else if let hostScreen, NSScreen.screens.contains(hostScreen) {
            let id = displayID(for: hostScreen)
            hostScreenID = id
            lastResolvedScreenID = id
            return hostScreen
        }

        if let main = NSScreen.main {
            let mainID = displayID(for: main)
            if lastResolvedScreenID != mainID {
                onScreenRecoveryEvent?(.switchedToFallbackMainScreen)
            }
            hostScreen = main
            hostScreenID = mainID
            lastResolvedScreenID = mainID
            return main
        }

        if let first = NSScreen.screens.first {
            let firstID = displayID(for: first)
            if lastResolvedScreenID != firstID {
                onScreenRecoveryEvent?(.switchedToFallbackFirstScreen)
            }
            hostScreen = first
            hostScreenID = firstID
            lastResolvedScreenID = firstID
            return first
        }

        hostScreen = nil
        hostScreenID = nil
        lastResolvedScreenID = nil
        return nil
    }

    private func align(panel: NSPanel, to screen: NSScreen) {
        hostScreen = screen
        let nextID = displayID(for: screen)
        hostScreenID = nextID
        lastResolvedScreenID = nextID
        let targetFrame = screen.visibleFrame
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func matchScreen(by id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { displayID(for: $0) == id })
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}

private struct CanvasNotificationToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

private enum ScreenDrawDismissalAnimationConstants {
    static let duration: Double = 0.62
    static let directionalFadeBand: CGFloat = 0.2
}

private final class ScreenDrawCanvasPanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    var visibilityHandler: ((Bool) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        onCloseRequested?()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        visibilityHandler?(false)
    }
}

private final class ScreenDrawCanvasView: NSView {
    private let sessionStore: ScreenDrawSessionStore
    private var cancellables: Set<AnyCancellable> = []

    override var isFlipped: Bool { true }

    init(sessionStore: ScreenDrawSessionStore) {
        self.sessionStore = sessionStore
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        let animationProgress = dismissalAnimationProgress()
        if sessionStore.isDismissingWithAnimation,
           let style = sessionStore.activeDismissalStyle {
            drawDismissalAnimatedShapes(
                style: style,
                progress: animationProgress,
                in: dirtyRect
            )
            return
        }

        for shape in sessionStore.shapes {
            draw(shape)
        }

        if let previewShape = sessionStore.previewShape {
            draw(previewShape)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !sessionStore.beginShapeDragIfNeeded(at: point) {
            sessionStore.beginInteraction(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if sessionStore.isDraggingExistingShape {
            sessionStore.continueShapeDrag(to: point)
        } else {
            sessionStore.continueInteraction(at: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if sessionStore.isDraggingExistingShape {
            sessionStore.endShapeDrag(at: point)
        } else {
            sessionStore.endInteraction(at: point)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        sessionStore.cancelActivePointerInteraction()
        needsDisplay = true
    }

    private func registerObservers() {
        sessionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &cancellables)

        let ticker = Timer.publish(
            every: 1.0 / 60.0,
            on: .main,
            in: .common
        ).autoconnect()
        ticker
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.sessionStore.isDismissingWithAnimation else { return }
                self.needsDisplay = true
            }
            .store(in: &cancellables)
    }

    private func draw(_ shape: ScreenDrawShape) {
        let effectiveColor = shape.colorPreset.color
        effectiveColor.setStroke()

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = shape.lineWidth

        switch shape.type {
        case .line:
            drawSmoothedTrail(shape.points, into: path)

        case .arrow:
            drawArrowTrail(shape, into: path)

        case .rectangle:
            path.appendRect(rect(from: shape.startPoint, to: shape.endPoint))

        case .ellipse:
            path.appendOval(in: rect(from: shape.startPoint, to: shape.endPoint))

        case .cross:
            drawCross(shape, into: path)

        case .check:
            drawCheck(shape, into: path)
        }

        path.stroke()
    }

    private func drawDismissalAnimatedShapes(
        style: DrawDismissalAnimationStyle,
        progress: CGFloat,
        in dirtyRect: CGRect
    ) {
        let clamped = max(0, min(progress, 1))
        switch style {
        case .leftToRight, .rightToLeft, .topToBottom, .bottomToTop:
            drawDirectionalDismissal(style: style, progress: clamped, in: dirtyRect)
        case .shatterDrop:
            drawShatterDropDismissal(progress: clamped)
        }
    }

    private func drawDirectionalDismissal(
        style: DrawDismissalAnimationStyle,
        progress: CGFloat,
        in dirtyRect: CGRect
    ) {
        let eased = smootherStep(progress)
        let fadeBand = ScreenDrawDismissalAnimationConstants.directionalFadeBand
        let sweep = -fadeBand + eased * (1 + fadeBand * 2)
        let lower = sweep - fadeBand
        let upper = sweep + fadeBand

        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = makeDirectionalMaskGradient(),
              let start = directionalMaskPoint(
                style: style,
                normalizedPosition: lower,
                in: dirtyRect
              ),
              let end = directionalMaskPoint(
                style: style,
                normalizedPosition: upper,
                in: dirtyRect
              ) else {
            let fallbackAlpha = max(0, min(1, 1 - eased))
            for shape in sessionStore.shapes {
                draw(shape, alpha: fallbackAlpha)
            }
            return
        }

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for shape in sessionStore.shapes {
            draw(shape)
        }
        context.setBlendMode(.destinationIn)
        context.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawShatterDropDismissal(progress: CGFloat) {
        let eased = easeIn(progress)
        let fragments = 16
        for index in 0 ..< fragments {
            let row = index / 4
            let col = index % 4
            let seed = fragmentSeed(index)
            let jitterX = (seed - 0.5) * 38
            let baseX = CGFloat(col) * 24 - 36 + jitterX * eased
            let baseY = CGFloat(row) * 6 + 12
            let dropDistance = (36 + CGFloat(row) * 12) * eased + pow(eased, 2) * 90
            let alpha = max(0, 1 - eased * 1.05)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.translateBy(
                x: baseX,
                y: dropDistance + baseY
            )

            for shape in sessionStore.shapes {
                let fragmentRect = fragmentRectForShape(shape, index: index, fragments: fragments)
                let clip = NSBezierPath(rect: fragmentRect)
                clip.addClip()
                draw(shape, alpha: alpha)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func fragmentRectForShape(_ shape: ScreenDrawShape, index: Int, fragments: Int) -> CGRect {
        let bounds = shapeBounds(shape).insetBy(dx: -8, dy: -8)
        guard bounds.width > 1, bounds.height > 1 else {
            return bounds
        }
        let rowCount = 4
        let columnCount = max(1, fragments / rowCount)
        let row = index / columnCount
        let col = index % columnCount
        let width = bounds.width / CGFloat(columnCount)
        let height = bounds.height / CGFloat(rowCount)
        return CGRect(
            x: bounds.minX + CGFloat(col) * width,
            y: bounds.minY + CGFloat(row) * height,
            width: width + 1,
            height: height + 1
        )
    }

    private func shapeBounds(_ shape: ScreenDrawShape) -> CGRect {
        switch shape.type {
        case .line, .arrow:
            guard !shape.points.isEmpty else {
                return CGRect(origin: shape.startPoint, size: .zero)
            }
            let xs = shape.points.map(\.x)
            let ys = shape.points.map(\.y)
            let minX = xs.min() ?? shape.startPoint.x
            let maxX = xs.max() ?? shape.endPoint.x
            let minY = ys.min() ?? shape.startPoint.y
            let maxY = ys.max() ?? shape.endPoint.y
            return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        case .rectangle, .ellipse, .cross, .check:
            return rect(from: shape.startPoint, to: shape.endPoint)
        }
    }

    private func draw(_ shape: ScreenDrawShape, alpha: CGFloat) {
        let effectiveColor = shape.colorPreset.color.withAlphaComponent(alpha)
        effectiveColor.setStroke()

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = shape.lineWidth

        switch shape.type {
        case .line:
            drawSmoothedTrail(shape.points, into: path)
        case .arrow:
            drawArrowTrail(shape, into: path)
        case .rectangle:
            path.appendRect(rect(from: shape.startPoint, to: shape.endPoint))
        case .ellipse:
            path.appendOval(in: rect(from: shape.startPoint, to: shape.endPoint))
        case .cross:
            drawCross(shape, into: path)
        case .check:
            drawCheck(shape, into: path)
        }

        path.stroke()
    }

    private func fragmentSeed(_ index: Int) -> CGFloat {
        let value = abs((index * 97 + 13).hashValue % 1000)
        return CGFloat(value) / 1000.0
    }

    private func dismissalAnimationProgress() -> CGFloat {
        let startedAt = sessionStore.dismissalAnimationStartedAt
        guard startedAt > 0 else { return 0 }
        let elapsed = CACurrentMediaTime() - startedAt
        let duration = ScreenDrawDismissalAnimationConstants.duration
        guard duration > 0 else { return 1 }
        return CGFloat(elapsed / duration)
    }

    private func easeIn(_ t: CGFloat) -> CGFloat {
        let clamped = max(0, min(t, 1))
        return clamped * clamped
    }

    private func smootherStep(_ t: CGFloat) -> CGFloat {
        let clamped = max(0, min(t, 1))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    private func makeDirectionalMaskGradient() -> CGGradient? {
        let colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(1).cgColor
        ] as CFArray
        let locations: [CGFloat] = [0, 1]
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        )
    }

    private func directionalMaskPoint(
        style: DrawDismissalAnimationStyle,
        normalizedPosition: CGFloat,
        in rect: CGRect
    ) -> CGPoint? {
        switch style {
        case .leftToRight:
            return CGPoint(
                x: rect.minX + rect.width * normalizedPosition,
                y: rect.midY
            )
        case .rightToLeft:
            return CGPoint(
                x: rect.maxX - rect.width * normalizedPosition,
                y: rect.midY
            )
        case .topToBottom:
            return CGPoint(
                x: rect.midX,
                y: rect.minY + rect.height * normalizedPosition
            )
        case .bottomToTop:
            return CGPoint(
                x: rect.midX,
                y: rect.maxY - rect.height * normalizedPosition
            )
        case .shatterDrop:
            return nil
        }
    }

    private func drawArrowTrail(_ shape: ScreenDrawShape, into path: NSBezierPath) {
        drawSmoothedTrail(shape.points, into: path)
        guard let (start, end) = arrowTangentPoints(for: shape) else { return }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }

        let ux = dx / length
        let uy = dy / length
        // Auto-correct arrow head by adapting size to recent stroke direction and velocity.
        let headScale = 1 + sessionStore.handDrawnIntensity * 0.2
        let headLength = max(shape.lineWidth * 3.0 * headScale, 10)
        let headWidth = max(shape.lineWidth * 2.0 * headScale, 8)

        let baseX = end.x - ux * headLength
        let baseY = end.y - uy * headLength
        let perpX = -uy
        let perpY = ux

        let left = CGPoint(x: baseX + perpX * headWidth * 0.5, y: baseY + perpY * headWidth * 0.5)
        let right = CGPoint(x: baseX - perpX * headWidth * 0.5, y: baseY - perpY * headWidth * 0.5)

        path.move(to: left)
        path.line(to: end)
        path.line(to: right)
    }

    private func drawSmoothedTrail(_ points: [CGPoint], into path: NSBezierPath) {
        guard let first = points.first else { return }

        if points.count == 1 {
            path.move(to: first)
            path.line(to: first)
            return
        }

        path.move(to: first)
        if points.count == 2 {
            path.line(to: points[1])
            return
        }

        var previousPoint = first
        for index in 1 ..< points.count {
            let current = points[index]
            let midpoint = CGPoint(
                x: (previousPoint.x + current.x) * 0.5,
                y: (previousPoint.y + current.y) * 0.5
            )
            path.curve(to: midpoint, controlPoint1: previousPoint, controlPoint2: midpoint)
            previousPoint = current
        }

        if let last = points.last {
            path.line(to: last)
        }
    }

    private func arrowTangentPoints(for shape: ScreenDrawShape) -> (CGPoint, CGPoint)? {
        let points = shape.points
        guard let end = points.last else { return nil }
        if points.count == 1 {
            return nil
        }

        // Use weighted samples near the tail to auto-correct arrow direction.
        let lastIndex = points.count - 1
        var weightedDX: CGFloat = 0
        var weightedDY: CGFloat = 0
        var totalWeight: CGFloat = 0
        var accumulated = 0

        for index in stride(from: lastIndex - 1, through: 0, by: -1) {
            let candidate = points[index]
            let segmentDX = end.x - candidate.x
            let segmentDY = end.y - candidate.y
            let segmentLength = hypot(segmentDX, segmentDY)
            if segmentLength < 0.001 {
                continue
            }

            let weight = CGFloat(max(1, 4 - accumulated))
            weightedDX += segmentDX * weight
            weightedDY += segmentDY * weight
            totalWeight += weight
            accumulated += 1

            if accumulated >= 4 {
                break
            }
        }

        if totalWeight > 0.001 {
            let avgStart = CGPoint(
                x: end.x - (weightedDX / totalWeight),
                y: end.y - (weightedDY / totalWeight)
            )
            let distance = hypot(end.x - avgStart.x, end.y - avgStart.y)
            if distance > 0.001 {
                return (avgStart, end)
            }
        }

        for index in stride(from: lastIndex - 1, through: 0, by: -1) {
            let candidate = points[index]
            let distance = hypot(end.x - candidate.x, end.y - candidate.y)
            if distance > 0.001 {
                return (candidate, end)
            }
        }
        return nil
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func drawCross(_ shape: ScreenDrawShape, into path: NSBezierPath) {
        let bounds = rect(from: shape.startPoint, to: shape.endPoint)
        guard bounds.width > 0.5, bounds.height > 0.5 else { return }

        let jitter = handDrawnSeed(for: shape)
        let intensity = max(0.0, min(sessionStore.handDrawnIntensity, 1.0))
        let styleFactor: CGFloat = sessionStore.markStyle == .rounded ? 1.0 : 0.62
        let swayX = bounds.width * (0.02 + intensity * 0.06 + jitter * 0.018) * styleFactor
        let swayY = bounds.height * (0.02 + intensity * 0.06 + jitter * 0.018) * styleFactor

        let aInset = sessionStore.markStyle == .rounded ? 0.10 : 0.07
        let a1 = CGPoint(x: bounds.minX + bounds.width * aInset, y: bounds.minY + bounds.height * 0.12)
        let a2 = CGPoint(x: bounds.maxX - bounds.width * 0.08, y: bounds.maxY - bounds.height * aInset)
        let aControl1 = CGPoint(x: bounds.minX + bounds.width * 0.34 + swayX, y: bounds.minY + bounds.height * 0.28 - swayY)
        let aControl2 = CGPoint(x: bounds.minX + bounds.width * 0.66 - swayX, y: bounds.minY + bounds.height * 0.72 + swayY)

        path.move(to: a1)
        path.curve(to: a2, controlPoint1: aControl1, controlPoint2: aControl2)

        let bInset = sessionStore.markStyle == .rounded ? 0.10 : 0.07
        let b1 = CGPoint(x: bounds.maxX - bounds.width * 0.08, y: bounds.minY + bounds.height * bInset)
        let b2 = CGPoint(x: bounds.minX + bounds.width * bInset, y: bounds.maxY - bounds.height * 0.08)
        let bControl1 = CGPoint(x: bounds.minX + bounds.width * 0.66 + swayX * 0.75, y: bounds.minY + bounds.height * 0.30 + swayY * 0.6)
        let bControl2 = CGPoint(x: bounds.minX + bounds.width * 0.34 - swayX * 0.75, y: bounds.minY + bounds.height * 0.70 - swayY * 0.6)

        path.move(to: b1)
        path.curve(to: b2, controlPoint1: bControl1, controlPoint2: bControl2)
    }

    private func drawCheck(_ shape: ScreenDrawShape, into path: NSBezierPath) {
        let bounds = rect(from: shape.startPoint, to: shape.endPoint)
        guard bounds.width > 0.5, bounds.height > 0.5 else { return }

        let jitter = handDrawnSeed(for: shape)
        let intensity = max(0.0, min(sessionStore.handDrawnIntensity, 1.0))
        let styleFactor: CGFloat = sessionStore.markStyle == .rounded ? 1.0 : 0.6
        let leftSway = bounds.width * (0.015 + intensity * 0.05 + jitter * 0.02) * styleFactor
        let rightSway = bounds.width * (0.02 + intensity * 0.05 + (1 - jitter) * 0.02) * styleFactor
        let verticalSway = bounds.height * (0.015 + intensity * 0.05 + jitter * 0.02) * styleFactor

        // isFlipped = true, so y increases downward.
        let start = CGPoint(
            x: bounds.minX + bounds.width * (sessionStore.markStyle == .rounded ? 0.14 : 0.11),
            y: bounds.minY + bounds.height * 0.60
        )
        let joint = CGPoint(
            x: bounds.minX + bounds.width * (sessionStore.markStyle == .rounded ? 0.38 : 0.36),
            y: bounds.minY + bounds.height * 0.84
        )
        let end = CGPoint(
            x: bounds.minX + bounds.width * (sessionStore.markStyle == .rounded ? 0.88 : 0.90),
            y: bounds.minY + bounds.height * (sessionStore.markStyle == .rounded ? 0.18 : 0.14)
        )

        let control1A = CGPoint(x: bounds.minX + bounds.width * 0.22 + leftSway, y: bounds.minY + bounds.height * 0.70 - verticalSway * 0.3)
        let control2A = CGPoint(x: bounds.minX + bounds.width * 0.31 - leftSway * 0.6, y: bounds.minY + bounds.height * 0.82 + verticalSway * 0.2)

        let control1B = CGPoint(x: bounds.minX + bounds.width * 0.47 + rightSway * 0.2, y: bounds.minY + bounds.height * 0.73 + verticalSway * 0.35)
        let control2B = CGPoint(x: bounds.minX + bounds.width * 0.73 - rightSway, y: bounds.minY + bounds.height * 0.36 - verticalSway * 0.8)

        path.move(to: start)
        path.curve(to: joint, controlPoint1: control1A, controlPoint2: control2A)
        path.curve(to: end, controlPoint1: control1B, controlPoint2: control2B)
    }

    private func handDrawnSeed(for shape: ScreenDrawShape) -> CGFloat {
        let value = abs(shape.id.uuidString.hashValue)
        let bucket = value % 997
        return CGFloat(bucket) / 997.0
    }

    func exportSnapshotImage() -> NSImage? {
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        bitmapRep.size = bounds.size
        cacheDisplay(in: bounds, to: bitmapRep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
