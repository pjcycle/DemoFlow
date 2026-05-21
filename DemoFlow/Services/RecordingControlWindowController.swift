//
//  RecordingControlWindowController.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit
import Foundation
import QuartzCore

enum RecordingControlMode {
    case readyToStart
    case recording
    case stopping
}

@MainActor
final class RecordingControlWindowController: NSObject {
    private var panel: RecordingControlPanel?
    private var observers: [NotificationToken] = []
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    private var mode: RecordingControlMode = .readyToStart

    var onStartRequested: (() -> Void)?
    var onStopRequested: (() -> Void)?

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

    func show(on screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let panel = panel ?? makePanel()
        let shouldReposition = !panel.isVisible
        if let targetScreen, shouldReposition {
            panel.setFrame(frame(for: panel, on: targetScreen), display: true)
        } else if shouldReposition {
            panel.center()
        }
        panel.collectionBehavior = desiredCollectionBehavior
        panel.level = .mainMenu
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        applyModeToView()
    }

    func hide() {
        panel?.orderOut(nil)
        mode = .readyToStart
        applyModeToView()
    }

    func setMode(_ mode: RecordingControlMode) {
        self.mode = mode
        applyModeToView()
    }

    func setStopping(_ stopping: Bool) {
        setMode(stopping ? .stopping : .recording)
    }

    private func applyModeToView() {
        guard let contentView = panel?.contentView as? RecordingControlView else { return }
        contentView.setMode(mode)
    }

    private func configureObservers() {
        let center = NotificationCenter.default
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

        let workspaceCenter = NSWorkspace.shared.notificationCenter
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
    }

    private func reassertFrontmost() {
        guard let panel, panel.isVisible else { return }
        panel.level = .mainMenu
        panel.collectionBehavior = desiredCollectionBehavior
        panel.orderFrontRegardless()
    }

    private func makePanel() -> RecordingControlPanel {
        let panel = RecordingControlPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.level = .mainMenu
        panel.identifier = NSUserInterfaceItemIdentifier("recording-control-window")
        panel.onControlTapped = { [weak self] in
            self?.handleControlTapped()
        }

        let contentView = RecordingControlView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
        contentView.autoresizingMask = [.width, .height]
        contentView.onControlTapped = { [weak self] in
            self?.handleControlTapped()
        }
        panel.contentView = contentView
        panel.initialFirstResponder = contentView
        contentView.setMode(mode)
        return panel
    }

    private func frame(for panel: NSPanel, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        return CGRect(
            x: visible.maxX - size.width - 28,
            y: visible.maxY - size.height - 72,
            width: size.width,
            height: size.height
        )
    }

    private func handleControlTapped() {
        switch mode {
        case .readyToStart:
            mode = .recording
            applyModeToView()
            onStartRequested?()
        case .recording:
            mode = .stopping
            applyModeToView()
            onStopRequested?()
        case .stopping:
            break
        }
    }
}

private struct NotificationToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

private final class RecordingControlPanel: NSPanel {
    var onControlTapped: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        onControlTapped?()
    }
}

private final class RecordingControlView: NSView {
    var onControlTapped: (() -> Void)?
    private let iconButton = NSButton()
    private let stoppingIndicator = NSProgressIndicator()
    private let recordingBreathAnimationKey = "demoflow.recording.breath"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        iconButton.title = ""
        iconButton.setButtonType(.momentaryChange)
        iconButton.isBordered = false
        iconButton.bezelStyle = .regularSquare
        iconButton.image = resolveSymbolImage(
            preferred: "camera.fill",
            fallback: "video.fill",
            description: L10n.tr("legacy.key_98")
        )
        iconButton.imagePosition = .imageOnly
        iconButton.symbolConfiguration = symbolConfig
        iconButton.contentTintColor = .labelColor
        iconButton.target = self
        iconButton.action = #selector(handleIconTapped)
        iconButton.sendAction(on: [.leftMouseDown])
        iconButton.translatesAutoresizingMaskIntoConstraints = false

        stoppingIndicator.style = .spinning
        stoppingIndicator.controlSize = .small
        stoppingIndicator.isDisplayedWhenStopped = false
        stoppingIndicator.isHidden = true
        stoppingIndicator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconButton)
        addSubview(stoppingIndicator)

        NSLayoutConstraint.activate([
            iconButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconButton.widthAnchor.constraint(equalToConstant: 36),
            iconButton.heightAnchor.constraint(equalToConstant: 36),

            stoppingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            stoppingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func setMode(_ mode: RecordingControlMode) {
        switch mode {
        case .readyToStart:
            iconButton.isEnabled = true
            iconButton.alphaValue = 1.0
            iconButton.image = resolveSymbolImage(
                preferred: "camera.fill",
                fallback: "video.fill",
                description: L10n.tr("legacy.key_98")
            )
            iconButton.contentTintColor = .labelColor
            stopRecordingBreathAnimation()
            stoppingIndicator.isHidden = true
            stoppingIndicator.stopAnimation(nil)
        case .recording:
            iconButton.isEnabled = true
            iconButton.alphaValue = 1.0
            iconButton.image = resolveSymbolImage(
                preferred: "stop.square.fill",
                fallback: "stop.fill",
                description: L10n.tr("legacy.key_15")
            )
            iconButton.contentTintColor = .systemRed
            startRecordingBreathAnimation()
            stoppingIndicator.isHidden = true
            stoppingIndicator.stopAnimation(nil)
        case .stopping:
            iconButton.isEnabled = false
            iconButton.alphaValue = 0.35
            stopRecordingBreathAnimation()
            stoppingIndicator.isHidden = false
            stoppingIndicator.startAnimation(nil)
        }
    }

    @objc
    private func handleIconTapped() {
        onControlTapped?()
    }

    private func startRecordingBreathAnimation() {
        guard let layer else { return }
        if layer.animation(forKey: recordingBreathAnimationKey) != nil {
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.84
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: recordingBreathAnimationKey)
    }

    private func stopRecordingBreathAnimation() {
        layer?.removeAnimation(forKey: recordingBreathAnimationKey)
    }

    private func resolveSymbolImage(
        preferred: String,
        fallback: String,
        description: String
    ) -> NSImage? {
        if let preferredImage = NSImage(systemSymbolName: preferred, accessibilityDescription: description) {
            return preferredImage
        }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: description)
    }
}
