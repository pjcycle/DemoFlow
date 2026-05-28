//
//  ScreenDrawToolbarWindowController.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/6.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class ScreenDrawToolbarWindowController: NSObject {
    enum ScreenRecoveryEvent {
        case switchedToFallbackMainScreen
        case switchedToFallbackFirstScreen
        case noAvailableScreen
        case frameRecomputedAfterScreenChange
    }

    private var panel: ScreenDrawToolbarPanel?
    private var hostScreen: NSScreen?
    private var hostScreenID: CGDirectDisplayID?
    private var lastResolvedScreenID: CGDirectDisplayID?
    private var observers: [NotificationToken] = []
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]
    private let sessionStore: ScreenDrawSessionStore
    private let toolbarOriginDefaultsKey = "screen_draw_toolbar_origin_v2"
    private let toolbarScreenIDDefaultsKey = "screen_draw_toolbar_screen_id_v2"

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

    var isKeyWindow: Bool {
        panel?.isKeyWindow == true
    }

    var currentWindowID: CGWindowID? {
        guard let windowNumber = panel?.windowNumber, windowNumber > 0 else { return nil }
        return CGWindowID(windowNumber)
    }

    var drawSessionStore: ScreenDrawSessionStore {
        sessionStore
    }

    func show(on screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let panel = panel ?? makePanel()
        let shouldReposition = !panel.isVisible
        if shouldReposition {
            let didRestore = restoreSavedFrameIfPossible(for: panel, preferredScreen: targetScreen)
            if !didRestore {
                if let targetScreen {
                    align(panel: panel, to: targetScreen)
                } else if let resolved = resolvedScreen() {
                    align(panel: panel, to: resolved)
                } else {
                    panel.center()
                    onScreenRecoveryEvent?(.noAvailableScreen)
                }
            }
        }
        panel.collectionBehavior = desiredCollectionBehavior
        panel.level = .statusBar
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        onVisibilityChanged?(true)
    }

    func hide() {
        panel?.orderOut(nil)
        onVisibilityChanged?(false)
    }

    private func makePanel() -> ScreenDrawToolbarPanel {
        let panel = ScreenDrawToolbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 84),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.tr("legacy.key_68")
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.level = .statusBar
        panel.collectionBehavior = desiredCollectionBehavior
        panel.onCloseRequested = { [weak self] in
            self?.handleCloseRequest()
        }
        panel.onMoved = { [weak self] frame in
            self?.persistToolbarFrame(frame)
        }

        let root = NSHostingView(
            rootView: ScreenDrawToolbarView(
                sessionStore: sessionStore,
                onCloseRequested: { [weak self] in
                    self?.handleCloseRequest()
                }
            )
        )
        root.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        panel.contentView = contentView
        return panel
    }

    private func configureObservers() {
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
                    Task { @MainActor [weak self] in
                        self?.reassertFrontmost()
                    }
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
                    Task { @MainActor [weak self] in
                        self?.reassertFrontmost()
                    }
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
                    Task { @MainActor [weak self] in
                        self?.reassertFrontmost()
                    }
                }
            )
        )

        observers.append(
            NotificationToken(
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

    private func handleCloseRequest() {
        if let onRequestClose {
            onRequestClose()
        } else {
            hide()
        }
    }

    private func reassertFrontmost() {
        guard let panel, panel.isVisible else { return }
        panel.level = .statusBar
        panel.collectionBehavior = desiredCollectionBehavior
        refreshFrameForCurrentScreen()
        panel.orderFrontRegardless()
    }

    private func refreshFrameForCurrentScreen(reason: ScreenRecoveryEvent? = nil) {
        guard let panel, panel.isVisible else { return }
        guard let targetScreen = resolvedScreen() else {
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
        let nextFrame = frame(for: panel, on: screen)
        if panel.frame != nextFrame {
            panel.setFrame(nextFrame, display: true)
        }
        persistToolbarFrame(panel.frame)
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

    private func frame(for panel: NSPanel, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        return CGRect(
            x: visible.midX - size.width / 2.0,
            y: visible.maxY - size.height - 28,
            width: size.width,
            height: size.height
        )
    }

    private func persistToolbarFrame(_ frame: CGRect) {
        let defaults = UserDefaults.standard
        defaults.set([frame.origin.x, frame.origin.y], forKey: toolbarOriginDefaultsKey)
        if let screenID = hostScreenID {
            defaults.set(Int(screenID), forKey: toolbarScreenIDDefaultsKey)
        } else if let panel, let screen = panel.screen, let screenID = displayID(for: screen) {
            defaults.set(Int(screenID), forKey: toolbarScreenIDDefaultsKey)
        }
    }

    private func restoreSavedFrameIfPossible(for panel: NSPanel, preferredScreen: NSScreen?) -> Bool {
        let defaults = UserDefaults.standard
        guard let origin = defaults.array(forKey: toolbarOriginDefaultsKey) as? [Double], origin.count == 2 else {
            return false
        }

        let savedOrigin = CGPoint(x: origin[0], y: origin[1])
        let size = panel.frame.size
        let candidate = CGRect(origin: savedOrigin, size: size)

        let preferredBySavedID: NSScreen?
        if defaults.object(forKey: toolbarScreenIDDefaultsKey) != nil {
            let savedID = defaults.integer(forKey: toolbarScreenIDDefaultsKey)
            preferredBySavedID = NSScreen.screens.first(where: {
                guard let id = displayID(for: $0) else { return false }
                return Int(id) == savedID
            })
        } else {
            preferredBySavedID = nil
        }

        guard let targetScreen = preferredBySavedID ?? preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return false
        }

        let clamped = clampedFrame(candidate, on: targetScreen)
        hostScreen = targetScreen
        let targetID = displayID(for: targetScreen)
        hostScreenID = targetID
        lastResolvedScreenID = targetID
        panel.setFrame(clamped, display: true)
        persistToolbarFrame(clamped)
        return true
    }

    private func clampedFrame(_ frame: CGRect, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let minX = visible.minX
        let maxX = visible.maxX - width
        let minY = visible.minY
        let maxY = visible.maxY - height
        let clampedX = min(max(frame.origin.x, minX), maxX)
        let clampedY = min(max(frame.origin.y, minY), maxY)
        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }
}

private struct NotificationToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

private final class ScreenDrawToolbarPanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    var onMoved: ((CGRect) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        onCloseRequested?()
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        onMoved?(frame)
    }
}

private struct ScreenDrawToolbarView: View {
    @ObservedObject var sessionStore: ScreenDrawSessionStore
    let onCloseRequested: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            closeDotButton

            HStack(spacing: 8) {
                ForEach(DrawColorPreset.allCases) { preset in
                    colorButton(preset)
                }
            }

            Divider()
                .frame(height: 30)

            HStack(spacing: 8) {
                ForEach(ScreenDrawTool.allCases) { tool in
                    toolButton(tool)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.01))
    }

    private var closeDotButton: some View {
        CloseDotButton(action: onCloseRequested)
            .help(L10n.tr("legacy.key_19"))
    }

    private func colorButton(_ preset: DrawColorPreset) -> some View {
        let isSelected = sessionStore.selectedColorPreset == preset
        return Button {
            sessionStore.selectedColorPreset = preset
        } label: {
            ZStack {
                // Keep full circular hit-testing even when using hollow ring style.
                Circle()
                    .fill(Color.clear)
                    .frame(width: 30, height: 30)

                if isSelected {
                    Circle()
                        .fill(Color(nsColor: preset.color))
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .stroke(Color(nsColor: preset.color), lineWidth: 1)
                        .frame(width: 30, height: 30)
                }
                Text(preset.shortLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(colorLabelTextColor(for: preset, isSelected: isSelected))
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(preset.title)
    }

    private func colorLabelTextColor(for preset: DrawColorPreset, isSelected: Bool) -> Color {
        if isSelected {
            switch preset {
            case .two:
                return .black
            default:
                return .white
            }
        }
        return Color(nsColor: preset.color)
    }

    private func toolButton(_ tool: ScreenDrawTool) -> some View {
        let isSelected = sessionStore.activeTool == tool
        return Button {
            sessionStore.activeTool = tool
        } label: {
            ZStack {
                // Keep full circular hit-testing even when icon/outline is thin.
                Circle()
                    .fill(Color.clear)

                if isSelected {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                } else {
                    Circle()
                        .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                }

                toolIcon(tool)
                    .frame(width: 20, height: 14)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tool.title)
    }

    @ViewBuilder
    private func toolIcon(_ tool: ScreenDrawTool) -> some View {
        let isSelected = sessionStore.activeTool == tool
        let selectedWeight: Font.Weight = .bold
        let normalWeight: Font.Weight = .semibold
        switch tool {
        case .line:
            HandDrawnLineSymbol(lineWidth: isSelected ? 2.0 : 1.1)
                .frame(width: 16, height: 10)
        case .arrow:
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: isSelected ? 14 : 13, weight: isSelected ? selectedWeight : normalWeight))
        case .cross:
            Image(systemName: tool.symbolName)
                .font(.caption.weight(isSelected ? selectedWeight : normalWeight))
        case .check:
            Image(systemName: tool.symbolName)
                .font(.caption.weight(isSelected ? selectedWeight : normalWeight))
        case .rectangle, .ellipse:
            Image(systemName: tool.symbolName)
                .font(.caption.weight(isSelected ? selectedWeight : normalWeight))
        }
    }
}

private struct CloseDotButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Keep full circular hit-testing for the close button.
                Circle()
                    .fill(Color.clear)
                    .frame(width: 30, height: 30)

                Circle()
                    .stroke(Color.primary.opacity(0.42), lineWidth: 1)
                    .frame(width: 30, height: 30)

                Circle()
                    .fill(Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.33, alpha: 1.0)))
                    .frame(width: 11, height: 11)

                if isHovering {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.7))
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct HandDrawnLineSymbol: View {
    let lineWidth: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1.2, y: 10.2))
            path.addCurve(
                to: CGPoint(x: 7.8, y: 5.2),
                control1: CGPoint(x: 3.2, y: 11.8),
                control2: CGPoint(x: 5.8, y: 4.2)
            )
            path.addCurve(
                to: CGPoint(x: 13.8, y: 8.3),
                control1: CGPoint(x: 9.5, y: 6.2),
                control2: CGPoint(x: 11.7, y: 10.2)
            )
            path.addCurve(
                to: CGPoint(x: 18.8, y: 3.7),
                control1: CGPoint(x: 15.3, y: 6.2),
                control2: CGPoint(x: 17.2, y: 2.8)
            )
        }
        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}
