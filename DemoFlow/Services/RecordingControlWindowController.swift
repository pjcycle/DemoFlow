//
//  RecordingControlWindowController.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit
import Foundation
import SwiftUI

enum RecordingControlMode: Equatable {
    case ready
    case recording
    case paused
    case stopping
}

struct RecordingControlDisplayModel: Equatable {
    var elapsedDisplay: String
    var captureSizeDisplay: String
    var captureMode: RecordingCaptureMode
    var selectedFixedCapturePreset: RecordingFixedCapturePreset?
    var isPiPActive: Bool
    var isAnnotateActive: Bool
    var canSelectCaptureSize: Bool
    var canRecordToggle: Bool
    var canPauseToggle: Bool
    var isMicrophoneMuted: Bool
    var hasMicrophoneInput: Bool
    var canToggleMicrophone: Bool
    var microphoneSourceName: String
    var canSelectMicrophone: Bool
    var canClose: Bool

    static let `default` = RecordingControlDisplayModel(
        elapsedDisplay: "00:00",
        captureSizeDisplay: "-- x --",
        captureMode: .fullScreen,
        selectedFixedCapturePreset: nil,
        isPiPActive: false,
        isAnnotateActive: false,
        canSelectCaptureSize: true,
        canRecordToggle: true,
        canPauseToggle: false,
        isMicrophoneMuted: false,
        hasMicrophoneInput: false,
        canToggleMicrophone: false,
        microphoneSourceName: "",
        canSelectMicrophone: false,
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
    private var captureSizePickerPopover: NSPopover?
    private var microphonePickerPopover: NSPopover?

    var onRecordToggleRequested: (() -> Void)?
    var onPauseToggleRequested: (() -> Void)?
    var onRegionToggleRequested: (() -> Void)?
    var onCaptureSizeTapped: (() -> Void)?
    var onPiPToggleRequested: (() -> Void)?
    var onAnnotateToggleRequested: (() -> Void)?
    var onMicrophoneToggleRequested: (() -> Void)?
    var onMicrophonePickerRequested: (() -> Void)?
    var onSettingsToggleRequested: (() -> Void)?
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
        hideCaptureSizePicker()
        hideMicrophonePicker()
        panel?.orderOut(nil)
        mode = .ready
        displayModel = .default
        applyViewState()
    }

    func setMode(_ mode: RecordingControlMode) {
        self.mode = mode
        if mode != .ready {
            hideCaptureSizePicker()
        }
        applyViewState()
    }

    func setDisplayModel(_ model: RecordingControlDisplayModel) {
        displayModel = model
        if !model.canSelectCaptureSize {
            hideCaptureSizePicker()
        }
        if !model.canSelectMicrophone {
            hideMicrophonePicker()
        }
        applyViewState()
    }

    func setElapsedDisplay(_ text: String) {
        displayModel.elapsedDisplay = text
        applyViewState()
    }

    /// 将控制条置于窗口选择高亮层之上。
    /// 窗口选择时仍需要点击尺寸/窗口按钮来切换目标窗口。
    func bringToFront() {
        reassertFrontmost()
    }

    func setCaptureSizeDisplay(_ text: String) {
        displayModel.captureSizeDisplay = text
        applyViewState()
    }

    func showCaptureSizePicker(
        options: [RecordingControlCaptureSizeOption],
        selectedOption: RecordingControlCaptureSizeOption?,
        onSelect: @escaping (RecordingControlCaptureSizeOption) -> Void
    ) {
        guard mode == .ready, displayModel.canSelectCaptureSize else { return }
        guard let contentView = panel?.contentView as? RecordingControlView else { return }
        let anchorView = contentView.captureSizeAnchorView

        let rootView = RecordingCaptureSizePickerView(
            options: options,
            selectedOption: selectedOption
        ) { [weak self] option in
            self?.hideCaptureSizePicker()
            onSelect(option)
        }

        let hostingController = NSHostingController(rootView: rootView)
        let popover = captureSizePickerPopover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 188, height: 322)
            captureSizePickerPopover = popover
            return popover
        }()
        if popover.isShown {
            popover.performClose(nil)
        }
        popover.contentViewController = hostingController
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func hideCaptureSizePicker() {
        captureSizePickerPopover?.performClose(nil)
    }

    func showMicrophonePicker(
        sources: [AudioInputSource],
        selectedSourceID: String?,
        isAuthorized: Bool,
        onRequestAccess: @escaping () -> Void,
        onSelect: @escaping (AudioInputSource) -> Void
    ) {
        guard mode == .ready, displayModel.canSelectMicrophone else { return }
        guard let contentView = panel?.contentView as? RecordingControlView else { return }

        let rootView = RecordingMicrophonePickerView(
            sources: sources,
            selectedSourceID: selectedSourceID,
            isAuthorized: isAuthorized,
            onRequestAccess: { [weak self] in
                self?.hideMicrophonePicker()
                onRequestAccess()
            },
            onSelect: { [weak self] source in
                self?.hideMicrophonePicker()
                onSelect(source)
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let contentSize = microphonePickerContentSize(
            sources: sources,
            isAuthorized: isAuthorized
        )
        let popover = microphonePickerPopover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            microphonePickerPopover = popover
            return popover
        }()
        if popover.isShown {
            popover.performClose(nil)
        }
        popover.contentSize = contentSize
        popover.contentViewController = hostingController
        popover.show(relativeTo: contentView.microphoneSelectionAnchorView.bounds,
                     of: contentView.microphoneSelectionAnchorView,
                     preferredEdge: .minY)
    }

    func hideMicrophonePicker() {
        microphonePickerPopover?.performClose(nil)
    }

    private func microphonePickerContentSize(
        sources: [AudioInputSource],
        isAuthorized: Bool
    ) -> NSSize {
        let availableCount = sources.filter(\.isAvailable).count
        let height: CGFloat
        if !isAuthorized {
            height = 116
        } else if availableCount == 0 {
            height = 76
        } else {
            // Title + padding + 32pt rows. Keep a scroll area only once the
            // device list needs it, instead of always reserving 220pt.
            height = min(220, 56 + CGFloat(availableCount) * 36)
        }
        return NSSize(width: 270, height: height)
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 46),
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

        let contentView = RecordingControlView(frame: NSRect(x: 0, y: 0, width: 520, height: 46))
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
        contentView.onCaptureSizeTapped = { [weak self] in
            self?.onCaptureSizeTapped?()
        }
        contentView.onPiPTapped = { [weak self] in
            self?.onPiPToggleRequested?()
        }
        contentView.onMicrophoneTapped = { [weak self] in
            self?.onMicrophoneToggleRequested?()
        }
        contentView.onMicrophoneSelectionTapped = { [weak self] in
            self?.onMicrophonePickerRequested?()
        }
        contentView.onSettingsTapped = { [weak self] in
            self?.onSettingsToggleRequested?()
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
            x: visible.midX - (size.width / 2.0),
            y: visible.maxY - size.height - 10,
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
    var onCaptureSizeTapped: (() -> Void)?
    var onPiPTapped: (() -> Void)?
    var onAnnotateTapped: (() -> Void)?
    var onRecordTapped: (() -> Void)?
    var onMicrophoneTapped: (() -> Void)?
    var onMicrophoneSelectionTapped: (() -> Void)?
    var onPauseTapped: (() -> Void)?
    var onSettingsTapped: (() -> Void)?
    var onCloseTapped: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let captureSizeButton = NSButton(title: "-- x --", target: nil, action: nil)
    private let regionButton = NSButton(title: "", target: nil, action: nil)
    private let pipButton = NSButton(title: "", target: nil, action: nil)
    private let annotateButton = NSButton(title: "", target: nil, action: nil)
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let microphoneButton = NSButton(title: "", target: nil, action: nil)
    private let microphoneSelectionButton = NSButton(title: "", target: nil, action: nil)
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
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

    var captureSizeAnchorView: NSView {
        captureSizeButton
    }

    var microphoneSelectionAnchorView: NSView {
        microphoneSelectionButton
    }

    func render(mode: RecordingControlMode, model: RecordingControlDisplayModel) {
        elapsedLabel.stringValue = model.elapsedDisplay
        updateCaptureSizeButton(title: model.captureSizeDisplay, isEnabled: model.canSelectCaptureSize)
        let isRegionMode = (model.captureMode == .region)
        let regionDescription = isRegionMode
            ? L10n.tr(RecordingCaptureMode.fullScreen.titleKey)
            : L10n.tr(RecordingCaptureMode.region.titleKey)
        regionButton.image = resolveSymbolImage(
            preferred: isRegionMode ? "rectangle.dashed" : "display",
            fallback: "rectangle",
            description: regionDescription
        )
        regionButton.contentTintColor = isRegionMode ? .systemBlue : .labelColor
        regionButton.alphaValue = isRegionMode ? 1.0 : 0.82
        pipButton.contentTintColor = model.isPiPActive ? .systemBlue : .labelColor
        pipButton.alphaValue = model.isPiPActive ? 1.0 : 0.82

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
        let microphoneIsMuted = model.isMicrophoneMuted || !model.hasMicrophoneInput
        let microphoneDescriptionKey: String = {
            guard model.hasMicrophoneInput else {
                return "recording.control.microphone_unavailable"
            }
            return microphoneIsMuted
                ? "recording.control.microphone_muted"
                : "recording.control.microphone_enabled"
        }()
        microphoneButton.image = resolveSymbolImage(
            preferred: microphoneIsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            fallback: microphoneIsMuted ? "speaker.slash" : "speaker.wave.2",
            description: L10n.tr(microphoneDescriptionKey)
        )
        microphoneButton.toolTip = L10n.tr(microphoneDescriptionKey)
        microphoneButton.setAccessibilityLabel(L10n.tr(microphoneDescriptionKey))
        microphoneButton.contentTintColor = model.canToggleMicrophone
            ? (microphoneIsMuted ? .systemOrange : .labelColor)
            : .tertiaryLabelColor
        microphoneButton.alphaValue = model.canToggleMicrophone ? 1.0 : 0.55

        let microphoneSelectionDescription = model.microphoneSourceName.isEmpty
            ? L10n.tr("recording.control.microphone_select")
            : L10n.f("recording.control.microphone_selected", model.microphoneSourceName)
        microphoneSelectionButton.image = resolveSymbolImage(
            preferred: "mic.fill",
            fallback: "mic",
            description: microphoneSelectionDescription
        )
        microphoneSelectionButton.toolTip = microphoneSelectionDescription
        microphoneSelectionButton.setAccessibilityLabel(microphoneSelectionDescription)
        microphoneSelectionButton.contentTintColor = model.canSelectMicrophone
            ? .labelColor
            : .tertiaryLabelColor
        microphoneSelectionButton.alphaValue = model.canSelectMicrophone ? 1.0 : 0.55

        let canPauseByMode = (mode == .recording || mode == .paused)
        let canRegionToggle = (mode == .ready)
        regionButton.isEnabled = canRegionToggle && model.canRecordToggle
        captureSizeButton.isEnabled = model.canSelectCaptureSize && mode == .ready
        recordButton.isEnabled = model.canRecordToggle && mode != .stopping
        pauseButton.isEnabled = model.canPauseToggle && canPauseByMode && mode != .stopping
        microphoneButton.isEnabled = model.canToggleMicrophone && mode == .recording
        microphoneSelectionButton.isEnabled = model.canSelectMicrophone && mode == .ready
        closeButton.isEnabled = model.canClose && mode != .stopping
        pipButton.isEnabled = mode != .stopping
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

        captureSizeButton.translatesAutoresizingMaskIntoConstraints = false
        captureSizeButton.bezelStyle = .regularSquare
        captureSizeButton.isBordered = false
        captureSizeButton.setButtonType(.momentaryPushIn)
        captureSizeButton.title = "-- x --"
        captureSizeButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        captureSizeButton.image = resolveSymbolImage(
            preferred: "chevron.down",
            fallback: "chevron.down",
            description: L10n.tr("recording.control.capture_size")
        )
        captureSizeButton.imagePosition = .imageRight
        captureSizeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        captureSizeButton.contentTintColor = .tertiaryLabelColor
        captureSizeButton.target = self
        captureSizeButton.action = #selector(handleCaptureSizeTapped)
        captureSizeButton.setContentHuggingPriority(.required, for: .horizontal)
        captureSizeButton.alignment = .left

        configureButton(
            regionButton,
            symbolName: "rectangle.dashed",
            fallbackName: "rectangle",
            description: L10n.tr("recording.control.region")
        )
        regionButton.action = #selector(handleRegionTapped)

        configureButton(
            pipButton,
            symbolName: "web.camera.fill",
            fallbackName: "web.camera",
            description: L10n.tr("legacy.pip_3")
        )
        pipButton.action = #selector(handlePiPTapped)

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
            microphoneButton,
            symbolName: "speaker.wave.2.fill",
            fallbackName: "speaker.wave.2",
            description: L10n.tr("recording.control.microphone_enabled")
        )
        microphoneButton.action = #selector(handleMicrophoneTapped)

        configureButton(
            microphoneSelectionButton,
            symbolName: "mic.fill",
            fallbackName: "mic",
            description: L10n.tr("recording.control.microphone_select")
        )
        microphoneSelectionButton.action = #selector(handleMicrophoneSelectionTapped)

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

        configureButton(
            settingsButton,
            symbolName: "gearshape.fill",
            fallbackName: "gearshape",
            description: L10n.tr("recording.control.settings")
        )
        settingsButton.action = #selector(handleSettingsTapped)

        let stack = NSStackView(views: [
            elapsedLabel,
            verticalSeparator(),
            captureSizeButton,
            verticalSeparator(),
            regionButton,
            pipButton,
            annotateButton,
            verticalSeparator(),
            recordButton,
            microphoneButton,
            microphoneSelectionButton,
            pauseButton,
            verticalSeparator(),
            settingsButton,
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
            captureSizeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            regionButton.widthAnchor.constraint(equalToConstant: 28),
            pipButton.widthAnchor.constraint(equalToConstant: 28),
            annotateButton.widthAnchor.constraint(equalToConstant: 28),
            recordButton.widthAnchor.constraint(equalToConstant: 28),
            microphoneButton.widthAnchor.constraint(equalToConstant: 28),
            microphoneSelectionButton.widthAnchor.constraint(equalToConstant: 28),
            pauseButton.widthAnchor.constraint(equalToConstant: 28),
            settingsButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            recordButton.heightAnchor.constraint(equalToConstant: 24),
            microphoneButton.heightAnchor.constraint(equalToConstant: 24),
            microphoneSelectionButton.heightAnchor.constraint(equalToConstant: 24),
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
    private func handleCaptureSizeTapped() {
        onCaptureSizeTapped?()
    }

    @objc
    private func handlePiPTapped() {
        onPiPTapped?()
    }

    @objc
    private func handleRecordTapped() {
        onRecordTapped?()
    }

    @objc
    private func handleMicrophoneTapped() {
        onMicrophoneTapped?()
    }

    @objc
    private func handleMicrophoneSelectionTapped() {
        onMicrophoneSelectionTapped?()
    }

    @objc
    private func handlePauseTapped() {
        onPauseTapped?()
    }

    @objc
    private func handleSettingsTapped() {
        onSettingsTapped?()
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

    private func updateCaptureSizeButton(title: String, isEnabled: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        captureSizeButton.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        captureSizeButton.contentTintColor = isEnabled ? .tertiaryLabelColor : .quaternaryLabelColor
        captureSizeButton.image = isEnabled
            ? resolveSymbolImage(
                preferred: "chevron.down",
                fallback: "chevron.down",
                description: L10n.tr("recording.control.capture_size")
            )
            : nil
    }
}

private struct RecordingCaptureSizePickerView: View {
    let options: [RecordingControlCaptureSizeOption]
    let selectedOption: RecordingControlCaptureSizeOption?
    let onSelect: (RecordingControlCaptureSizeOption) -> Void

    private var landscapeOptions: [RecordingControlCaptureSizeOption] {
        options.filter { option in
            guard case let .preset(preset) = option else { return false }
            return preset.aspectLabel == "16:9"
        }
    }

    private var portraitOptions: [RecordingControlCaptureSizeOption] {
        options.filter { option in
            guard case let .preset(preset) = option else { return false }
            return preset.aspectLabel == "9:16"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            optionButton(for: .freeform)

            if !landscapeOptions.isEmpty {
                groupSection(title: "16:9", options: landscapeOptions)
            }

            if !portraitOptions.isEmpty {
                groupSection(title: "9:16", options: portraitOptions)
            }

            if options.contains(.window) {
                Divider().padding(.vertical, 4)
                windowOptionButton()
            }
        }
        .padding(10)
        .frame(width: 188, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func groupSection(title: String, options: [RecordingControlCaptureSizeOption]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 4) {
                ForEach(options) { option in
                    optionButton(for: option)
                }
            }
        }
    }

    private func optionButton(for option: RecordingControlCaptureSizeOption) -> some View {
        let isSelected = selectedOption == option
        return Button {
            onSelect(option)
        } label: {
            HStack(spacing: 8) {
                Text(title(for: option))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func title(for option: RecordingControlCaptureSizeOption) -> String {
        switch option {
        case .freeform:
            return L10n.tr("recording.capture_size.freeform")
        case let .preset(preset):
            return preset.displayText
        case .window:
            return L10n.tr("recording.capture_mode.window")
        }
    }

    private func windowOptionButton() -> some View {
        let isSelected = selectedOption == .window
        return Button {
            onSelect(.window)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                Text(L10n.tr("recording.capture_mode.window"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RecordingMicrophonePickerView: View {
    let sources: [AudioInputSource]
    let selectedSourceID: String?
    let isAuthorized: Bool
    let onRequestAccess: () -> Void
    let onSelect: (AudioInputSource) -> Void

    private var availableSources: [AudioInputSource] {
        sources.filter(\.isAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("recording.control.microphone_select"))
                .font(.headline)

            if !isAuthorized {
                Text(L10n.tr("recording.control.microphone_permission_required"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.tr("legacy.key_204"), action: onRequestAccess)
                    .buttonStyle(.borderedProminent)
            } else if availableSources.isEmpty {
                Text(L10n.tr("recording.control.microphone_unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(availableSources) { source in
                            Button {
                                onSelect(source)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: source.id == selectedSourceID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(source.id == selectedSourceID ? Color.accentColor : Color.secondary)
                                    Text(source.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if !source.badgeText.isEmpty {
                                        Text(source.badgeText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 270, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
