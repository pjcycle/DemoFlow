//
//  RecordingControlWindowController.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit
import Foundation

enum RecordingControlMode {
    case ready
    case recording
    case paused
    case stopping
}

struct RecordingControlDisplayModel: Equatable {
    var elapsedDisplay: String
    var captureSizeDisplay: String
    var isAnnotateActive: Bool
    var canRecordToggle: Bool
    var canPauseToggle: Bool
    var canClose: Bool

    static let `default` = RecordingControlDisplayModel(
        elapsedDisplay: "00:00:00",
        captureSizeDisplay: "-- x --",
        isAnnotateActive: false,
        canRecordToggle: true,
        canPauseToggle: false,
        canClose: true
    )
}

@MainActor
final class RecordingControlWindowController: NSObject {
    private var panel: RecordingControlPanel?
    private var observers: [NotificationToken] = []
    private let desiredCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    private var mode: RecordingControlMode = .ready
    private var displayModel: RecordingControlDisplayModel = .default

    var onRecordToggleRequested: (() -> Void)?
    var onPauseToggleRequested: (() -> Void)?
    var onRegionToggleRequested: (() -> Void)?
    var onAnnotateToggleRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?

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
        panel.level = .statusBar
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        applyViewState()
    }

    func hide() {
        panel?.orderOut(nil)
        mode = .ready
        displayModel = .default
        applyViewState()
    }

    func setMode(_ mode: RecordingControlMode) {
        self.mode = mode
        applyViewState()
    }

    func setDisplayModel(_ model: RecordingControlDisplayModel) {
        displayModel = model
        applyViewState()
    }

    func setElapsedDisplay(_ text: String) {
        displayModel.elapsedDisplay = text
        applyViewState()
    }

    func setCaptureSizeDisplay(_ text: String) {
        displayModel.captureSizeDisplay = text
        applyViewState()
    }

    func setAnnotateActive(_ isActive: Bool) {
        displayModel.isAnnotateActive = isActive
        applyViewState()
    }

    func setControlAvailability(
        canRecordToggle: Bool? = nil,
        canPauseToggle: Bool? = nil,
        canClose: Bool? = nil
    ) {
        if let canRecordToggle {
            displayModel.canRecordToggle = canRecordToggle
        }
        if let canPauseToggle {
            displayModel.canPauseToggle = canPauseToggle
        }
        if let canClose {
            displayModel.canClose = canClose
        }
        applyViewState()
    }

    private func applyViewState() {
        guard let contentView = panel?.contentView as? RecordingControlView else { return }
        contentView.render(mode: mode, model: displayModel)
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
        panel.level = .statusBar
        panel.collectionBehavior = desiredCollectionBehavior
        panel.orderFrontRegardless()
    }

    private func makePanel() -> RecordingControlPanel {
        let panel = RecordingControlPanel(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 46),
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
        panel.level = .statusBar
        panel.identifier = NSUserInterfaceItemIdentifier("recording-control-window")
        panel.onCloseRequested = { [weak self] in
            self?.onCloseRequested?()
        }

        let contentView = RecordingControlView(frame: NSRect(x: 0, y: 0, width: 332, height: 46))
        contentView.autoresizingMask = [.width, .height]
        contentView.onAnnotateTapped = { [weak self] in
            self?.onAnnotateToggleRequested?()
        }
        contentView.onRecordTapped = { [weak self] in
            self?.onRecordToggleRequested?()
        }
        contentView.onPauseTapped = { [weak self] in
            self?.onPauseToggleRequested?()
        }
        contentView.onRegionTapped = { [weak self] in
            self?.onRegionToggleRequested?()
        }
        contentView.onCloseTapped = { [weak self] in
            self?.onCloseRequested?()
        }
        panel.contentView = contentView
        panel.initialFirstResponder = contentView
        contentView.render(mode: mode, model: displayModel)
        return panel
    }

    private func frame(for panel: NSPanel, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        return CGRect(
            x: visible.maxX - size.width - 26,
            y: visible.maxY - size.height - 74,
            width: size.width,
            height: size.height
        )
    }
}

private struct NotificationToken {
    let center: NotificationCenter
    let token: NSObjectProtocol
}

private final class RecordingControlPanel: NSPanel {
    var onCloseRequested: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        onCloseRequested?()
    }
}

private final class RecordingControlView: NSView {
    var onRegionTapped: (() -> Void)?
    var onAnnotateTapped: (() -> Void)?
    var onRecordTapped: (() -> Void)?
    var onPauseTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let elapsedLabel = NSTextField(labelWithString: "00:00:00")
    private let captureSizeLabel = NSTextField(labelWithString: "-- x --")
    private let regionButton = NSButton(title: "", target: nil, action: nil)
    private let annotateButton = NSButton(title: "", target: nil, action: nil)
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let stoppingIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(mode: RecordingControlMode, model: RecordingControlDisplayModel) {
        elapsedLabel.stringValue = model.elapsedDisplay
        captureSizeLabel.stringValue = model.captureSizeDisplay

        switch mode {
        case .ready:
            recordButton.image = resolveSymbolImage(
                preferred: "record.circle.fill",
                fallback: "record.circle",
                description: L10n.tr("legacy.key_102")
            )
            recordButton.contentTintColor = .systemRed
            pauseButton.image = resolveSymbolImage(
                preferred: "pause.fill",
                fallback: "pause",
                description: L10n.tr("recording.control.pause")
            )
            pauseButton.contentTintColor = .labelColor
        case .recording:
            recordButton.image = resolveSymbolImage(
                preferred: "stop.square.fill",
                fallback: "stop.fill",
                description: L10n.tr("legacy.key_15")
            )
            recordButton.contentTintColor = .systemRed
            pauseButton.image = resolveSymbolImage(
                preferred: "pause.fill",
                fallback: "pause",
                description: L10n.tr("recording.control.pause")
            )
            pauseButton.contentTintColor = .labelColor
        case .paused:
            recordButton.image = resolveSymbolImage(
                preferred: "record.circle.fill",
                fallback: "record.circle",
                description: L10n.tr("legacy.key_102")
            )
            recordButton.contentTintColor = .systemRed
            pauseButton.image = resolveSymbolImage(
                preferred: "play.fill",
                fallback: "play",
                description: L10n.tr("recording.control.resume")
            )
            pauseButton.contentTintColor = .labelColor
        case .stopping:
            recordButton.image = resolveSymbolImage(
                preferred: "stop.square.fill",
                fallback: "stop.fill",
                description: L10n.tr("legacy.key_169")
            )
            recordButton.contentTintColor = .systemRed
            pauseButton.image = resolveSymbolImage(
                preferred: "pause.fill",
                fallback: "pause",
                description: L10n.tr("recording.control.pause")
            )
            pauseButton.contentTintColor = .labelColor
        }

        annotateButton.contentTintColor = model.isAnnotateActive ? .systemBlue : .labelColor
        annotateButton.alphaValue = model.isAnnotateActive ? 1.0 : 0.82

        let canPauseByMode = (mode == .recording || mode == .paused)
        let canRegionToggle = (mode == .ready)
        regionButton.isEnabled = canRegionToggle && model.canRecordToggle
        recordButton.isEnabled = model.canRecordToggle && mode != .stopping
        pauseButton.isEnabled = model.canPauseToggle && canPauseByMode && mode != .stopping
        closeButton.isEnabled = model.canClose && mode != .stopping
        annotateButton.isEnabled = mode != .stopping

        let isStopping = (mode == .stopping)
        stoppingIndicator.isHidden = !isStopping
        if isStopping {
            stoppingIndicator.startAnimation(nil)
        } else {
            stoppingIndicator.stopAnimation(nil)
        }
    }

    private func configureSubviews() {
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 11
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.borderWidth = 0
        effectView.layer?.borderColor = NSColor.clear.cgColor
        effectView.alphaValue = 0.8
        addSubview(effectView)

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        elapsedLabel.textColor = .labelColor
        elapsedLabel.alignment = .left
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)

        captureSizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        captureSizeLabel.textColor = .secondaryLabelColor
        captureSizeLabel.alignment = .left
        captureSizeLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureButton(
            regionButton,
            symbolName: "rectangle.dashed",
            fallbackName: "rectangle",
            description: L10n.tr("recording.control.region")
        )
        regionButton.action = #selector(handleRegionTapped)

        configureButton(
            annotateButton,
            symbolName: "highlighter",
            fallbackName: "pencil",
            description: L10n.tr("recording.control.annotate")
        )
        annotateButton.title = ""
        annotateButton.imagePosition = .imageOnly
        annotateButton.font = .systemFont(ofSize: 12, weight: .semibold)
        annotateButton.contentTintColor = .labelColor
        annotateButton.action = #selector(handleAnnotateTapped)

        configureButton(
            recordButton,
            symbolName: "record.circle.fill",
            fallbackName: "record.circle",
            description: L10n.tr("legacy.key_102")
        )
        recordButton.action = #selector(handleRecordTapped)

        configureButton(
            pauseButton,
            symbolName: "pause.fill",
            fallbackName: "pause",
            description: L10n.tr("recording.control.pause")
        )
        pauseButton.action = #selector(handlePauseTapped)

        configureButton(
            closeButton,
            symbolName: "xmark",
            fallbackName: "xmark",
            description: L10n.tr("recording.control.close")
        )
        closeButton.action = #selector(handleCloseTapped)

        let stack = NSStackView(views: [
            elapsedLabel,
            verticalSeparator(),
            captureSizeLabel,
            verticalSeparator(),
            regionButton,
            annotateButton,
            verticalSeparator(),
            recordButton,
            pauseButton,
            closeButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)

        stoppingIndicator.style = .spinning
        stoppingIndicator.controlSize = .small
        stoppingIndicator.isDisplayedWhenStopped = false
        stoppingIndicator.isHidden = true
        stoppingIndicator.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stoppingIndicator)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            captureSizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            regionButton.widthAnchor.constraint(equalToConstant: 28),
            annotateButton.widthAnchor.constraint(equalToConstant: 28),
            recordButton.widthAnchor.constraint(equalToConstant: 28),
            pauseButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            recordButton.heightAnchor.constraint(equalToConstant: 24),
            pauseButton.heightAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            stoppingIndicator.centerXAnchor.constraint(equalTo: recordButton.centerXAnchor),
            stoppingIndicator.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor)
        ])
    }

    private func configureButton(
        _ button: NSButton,
        symbolName: String,
        fallbackName: String,
        description: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.title = ""
        button.image = resolveSymbolImage(
            preferred: symbolName,
            fallback: fallbackName,
            description: description
        )
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        button.target = self
    }

    private func verticalSeparator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 20)
        ])
        return separator
    }

    @objc
    private func handleAnnotateTapped() {
        onAnnotateTapped?()
    }

    @objc
    private func handleRegionTapped() {
        onRegionTapped?()
    }

    @objc
    private func handleRecordTapped() {
        onRecordTapped?()
    }

    @objc
    private func handlePauseTapped() {
        onPauseTapped?()
    }

    @objc
    private func handleCloseTapped() {
        onCloseTapped?()
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
