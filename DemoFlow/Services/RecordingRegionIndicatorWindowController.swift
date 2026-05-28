//
//  RecordingRegionIndicatorWindowController.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/25.
//

import AppKit
import Foundation

@MainActor
final class RecordingRegionIndicatorWindowController: NSObject {
    private var panel: RecordingRegionIndicatorPanel?
    private var indicatorView: RecordingRegionIndicatorView?
    private var observers: [RecordingRegionIndicatorToken] = []
    private var activeSelection: RecordingRegionSelection?
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]

    override init() {
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

    @discardableResult
    func show(selection: RecordingRegionSelection) -> Bool {
        guard let screen = NSScreen.screen(with: selection.displayID) else {
            hide()
            return false
        }
        activeSelection = selection

        let panel = panel ?? makePanel(on: screen)
        align(panel: panel, to: screen)
        indicatorView?.regionRect = selection.rectInDisplayPoints
        panel.level = .mainMenu
        panel.collectionBehavior = desiredCollectionBehavior
        panel.orderFrontRegardless()
        self.panel = panel
        return true
    }

    func hide() {
        panel?.orderOut(nil)
        activeSelection = nil
    }

    private func makePanel(on screen: NSScreen) -> RecordingRegionIndicatorPanel {
        let panel = RecordingRegionIndicatorPanel(
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
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.level = .mainMenu
        panel.collectionBehavior = desiredCollectionBehavior
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("recording-region-indicator-window")

        let indicatorView = RecordingRegionIndicatorView(frame: panel.contentView?.bounds ?? .zero)
        indicatorView.autoresizingMask = [.width, .height]
        panel.contentView = indicatorView
        self.indicatorView = indicatorView
        return panel
    }

    private func align(panel: NSPanel, to screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
        indicatorView?.frame = panel.contentView?.bounds ?? .zero
    }

    private func configureObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(
            RecordingRegionIndicatorToken(
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
            RecordingRegionIndicatorToken(
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
            RecordingRegionIndicatorToken(
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
        guard let selection = activeSelection,
              let screen = NSScreen.screen(with: selection.displayID),
              let panel else { return }
        align(panel: panel, to: screen)
        indicatorView?.regionRect = selection.rectInDisplayPoints
        panel.level = .mainMenu
        panel.collectionBehavior = desiredCollectionBehavior
        panel.orderFrontRegardless()
    }
}

private struct RecordingRegionIndicatorToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

private final class RecordingRegionIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingRegionIndicatorView: NSView {
    var regionRect: CGRect = .zero {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let clampedRect = regionRect.standardized.intersection(bounds)
        guard clampedRect.width >= 2, clampedRect.height >= 2 else { return }

        let borderPath = NSBezierPath(rect: clampedRect.insetBy(dx: 1, dy: 1))
        borderPath.lineWidth = 2
        borderPath.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.95).setStroke()
        borderPath.stroke()
    }
}
