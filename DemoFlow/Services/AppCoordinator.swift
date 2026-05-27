//
//  AppCoordinator.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum PiPFilmStopTrigger {
    case manual
    case hide
    case close
}

private enum RecordingSessionStopIntent {
    case none
    case pause
    case finalize
}

@MainActor
final class AppCoordinator: ObservableObject {
    private static let languageOptionDefaultsKey = "demoflow.appLanguage.option"
    private static let privacyNoticePresentedDefaultsKey = "demoflow.privacy.notice.presented"
    // TODO: replace with production GitHub Pages base URL.
    private static let privacyPolicyBaseURL = "https://pjcycle.github.io/pjln"
    private static let drawDismissalAnimationModeDefaultsKey = "demoflow.draw.dismissal.animation.mode"
    private static let drawDismissalAnimationFixedStyleDefaultsKey = "demoflow.draw.dismissal.animation.fixedStyle"
    private static let drawAutoCaptureOnCloseEnabledDefaultsKey = "demoflow.draw.autoCaptureOnClose.enabled"
    private static let recordingQualityPresetDefaultsKey = "demoflow.recording.quality.preset"
    private static let recordingQualityCustomResolutionDefaultsKey = "demoflow.recording.quality.custom.resolution"
    private static let recordingQualityCustomFPSDefaultsKey = "demoflow.recording.quality.custom.fps"
    private static let recordingQualityCustomCodecDefaultsKey = "demoflow.recording.quality.custom.codec"
    private static let recordingQualityCustomBitrateDefaultsKey = "demoflow.recording.quality.custom.videoBitrateMbps"
    private static let recordingAllCaptureEnabledDefaultsKey = "demoflow.recording.allCapture.enabled"
    private static let pipRecordingQualityPresetDefaultsKey = "demoflow.pip.recording.quality.preset"
    private static let pipRecordingQualityCustomBitrateDefaultsKey = "demoflow.pip.recording.quality.custom.videoBitrateMbps"
    private static let pipHotkeyRegisteredStatusKey = "pip.hotkey.registered.status"
    private static let pipHotkeyFallbackStatusKey = "pip.hotkey.fallback.status"
    private static let pipFilmTitleRecordingSuffix = " - 录像中"
    @Published private(set) var isRecordingArmed = false
    @Published var enableCameraPiP = false {
        didSet {
            guard enableCameraPiP != oldValue else { return }
            if !enableCameraPiP {
                hidePiPPreview()
            }
        }
    }
    @Published var pipLayout = PiPLayoutState.default
    @Published var pipAspectRatio: PiPAspectRatio = .auto {
        didSet {
            guard pipAspectRatio != oldValue else { return }
            pipLayout.aspectRatio = pipAspectRatio
            let nextAspectRatio = pipAspectRatio
            DispatchQueue.main.async { [weak self] in
                self?.pipController.updateAspectRatio(nextAspectRatio)
            }
        }
    }
    @Published var pipWindowConfig: PiPWindowConfig = .default {
        didSet {
            guard pipWindowConfig != oldValue else { return }
            pipController.applyWindowConfig(pipWindowConfig)
        }
    }
    @Published var pipAudioPreviewConfig: PiPAudioPreviewConfig = .default {
        didSet {
            guard pipAudioPreviewConfig != oldValue else { return }
            pipPreviewRuntime.applyPreviewAudioConfig(pipAudioPreviewConfig)
        }
    }
    @Published var pipProcessingConfig: PiPProcessingConfig = .default
    @Published var recordingCaptureMode: RecordingCaptureMode = .fullScreen
    @Published var recordingFixedCapturePreset: RecordingFixedCapturePreset?
    @Published var recordingQualityConfig: RecordingQualityConfig = .defaultConfig {
        didSet {
            let normalized = recordingQualityConfig.normalized()
            if normalized != recordingQualityConfig {
                recordingQualityConfig = normalized
                return
            }
            guard recordingQualityConfig != oldValue else { return }
            persistRecordingQualityConfig()
        }
    }
    @Published var isAllRecordingEnabled = false {
        didSet {
            guard isAllRecordingEnabled != oldValue else { return }
            persistAllRecordingEnabled()
        }
    }
    @Published var pipRecordingQualityConfig: PiPRecordingQualityConfig = .defaultConfig {
        didSet {
            let normalized = pipRecordingQualityConfig.normalized()
            if normalized != pipRecordingQualityConfig {
                pipRecordingQualityConfig = normalized
                return
            }
            guard pipRecordingQualityConfig != oldValue else { return }
            persistPiPRecordingQualityConfig()
        }
    }
    @Published var selectedSettingsSection: SettingsSection = .recording
    @Published var languageOption: AppLanguageOption = .auto {
        didSet {
            guard languageOption != oldValue else { return }
            persistLanguageOption()
            resolveLanguage()
        }
    }
    @Published var isSidebarCollapsed = false
    @Published var sidebarWidth: CGFloat = 280

    @Published private(set) var resolvedLanguage: ResolvedAppLanguage = .en
    @Published private(set) var statusMessage = L10n.tr("legacy.key_115")
    @Published private(set) var pipStatusMessage = L10n.tr("legacy.pip_2")
    @Published private(set) var pipFilmState: PiPFilmRecordingState = .idle
    @Published private(set) var lastPiPFilmOutputURL: URL?
    @Published private(set) var isPiPPreviewVisible = false
    @Published private(set) var drawStatusMessage = L10n.tr("legacy.key_75")
    @Published private(set) var isDrawOverlayVisible = false
    @Published private(set) var isDrawCanvasInteractionEnabled = true
    @Published private(set) var isDrawGlobalHotkeysEnabled = false
    @Published private(set) var isPiPGlobalHotkeysEnabled = false
    @Published var isDrawAutoCaptureOnCloseEnabled = false {
        didSet {
            guard isDrawAutoCaptureOnCloseEnabled != oldValue else { return }
            persistDrawAutoCaptureOnCloseEnabled()
        }
    }
    @Published var drawDismissalAnimationMode: DrawDismissalAnimationMode = .random {
        didSet {
            guard drawDismissalAnimationMode != oldValue else { return }
            screenDrawCanvasController.drawSessionStore.dismissalAnimationMode = drawDismissalAnimationMode
            persistDrawDismissalAnimationMode()
        }
    }
    @Published var drawDismissalAnimationFixedStyle: DrawDismissalAnimationStyle = .shatterDrop {
        didSet {
            guard drawDismissalAnimationFixedStyle != oldValue else { return }
            screenDrawCanvasController.drawSessionStore.dismissalAnimationFixedStyle = drawDismissalAnimationFixedStyle
            persistDrawDismissalAnimationFixedStyle()
        }
    }
    @Published private(set) var recorderState: RecordingState = .idle
    @Published private(set) var isRecordingPermissionRequestInFlight = false
    @Published private(set) var isRecordingRegionSelecting = false
    @Published private(set) var recordingRegionSelectionSizeText = "400 x 400"
    @Published private(set) var isPrivacyNoticePresented = false
    @Published private(set) var privacyPolicyOpenErrorMessage: String?

    let audioEngine: AudioInputEngine
    let pipPreviewRuntime: PiPPreviewRuntime
    let pipController: PiPOverlayWindowController
    let screenDrawToolbarController: ScreenDrawToolbarWindowController
    let screenDrawCanvasController: ScreenDrawCanvasWindowController
    let recordingControlController: RecordingControlWindowController
    let recordingRegionSelectionController: RecordingRegionSelectionWindowController
    let recordingRegionIndicatorController: RecordingRegionIndicatorWindowController
    let recorder: ScreenRecorderEngine

    private let screenDrawHotkeyService: ScreenDrawHotkeyService
    private let pipHotkeyService: PiPHotkeyService
    private let quickActionHotkeyService: QuickActionHotkeyService
    private let pipFilmRecorder = PiPFilmRecorderService()
    private let screenDrawAutoCaptureService = ScreenDrawAutoCaptureService()
    private let compositionEngine = CompositionExportEngine()
    private var cancellables: Set<AnyCancellable> = []
    private var shouldRestoreMainWindowAfterRecording = false
    private var drawSystemDefinedMonitor: Any?
    private var pendingDrawCaptureRefreshTask: Task<Void, Never>?
    private var isSuppressingPiPHideCallback = false
    private var pendingPiPFilmStopTrigger: PiPFilmStopTrigger?
    private var armedRecordingCaptureMode: RecordingCaptureMode = .fullScreen
    private var pendingRegionSelection: RecordingRegionSelection?
    private var activeRecordingRegionSelection: RecordingRegionSelection?
    private var recordingControlMode: RecordingControlMode = .ready
    private var recordingControlDisplayModel: RecordingControlDisplayModel = .default
    private var recordingSessionSegmentURLs: [URL] = []
    private var recordingSessionElapsedBeforeCurrentSegment: TimeInterval = 0
    private var recordingSessionCurrentSegmentStart: Date?
    private var recordingSessionTimer: Timer?
    private var recordingControlSizeRefreshTimer: Timer?
    private var recordingSessionLockedCaptureSizeDisplay: String?
    private var recordingSessionStopIntent: RecordingSessionStopIntent = .none
    private var hasEvaluatedPrivacyNoticeThisLaunch = false
    private var hasBootstrapped = false

    convenience init() {
        let drawSessionStore = ScreenDrawSessionStore()
        self.init(
            audioEngine: AudioInputEngine(),
            recordingCameraEngine: CameraEngine(),
            pipPreviewRuntime: PiPPreviewRuntime(),
            pipController: PiPOverlayWindowController(),
            screenDrawToolbarController: ScreenDrawToolbarWindowController(sessionStore: drawSessionStore),
            screenDrawCanvasController: ScreenDrawCanvasWindowController(sessionStore: drawSessionStore),
            recordingControlController: RecordingControlWindowController(),
            recordingRegionSelectionController: RecordingRegionSelectionWindowController(),
            recordingRegionIndicatorController: RecordingRegionIndicatorWindowController(),
            screenDrawHotkeyService: ScreenDrawHotkeyService(),
            pipHotkeyService: PiPHotkeyService(),
            quickActionHotkeyService: QuickActionHotkeyService()
        )
    }

    init(
        audioEngine: AudioInputEngine,
        recordingCameraEngine: CameraEngine,
        pipPreviewRuntime: PiPPreviewRuntime,
        pipController: PiPOverlayWindowController,
        screenDrawToolbarController: ScreenDrawToolbarWindowController,
        screenDrawCanvasController: ScreenDrawCanvasWindowController,
        recordingControlController: RecordingControlWindowController,
        recordingRegionSelectionController: RecordingRegionSelectionWindowController,
        recordingRegionIndicatorController: RecordingRegionIndicatorWindowController,
        screenDrawHotkeyService: ScreenDrawHotkeyService,
        pipHotkeyService: PiPHotkeyService,
        quickActionHotkeyService: QuickActionHotkeyService
    ) {
        self.audioEngine = audioEngine
        self.pipPreviewRuntime = pipPreviewRuntime
        self.pipController = pipController
        self.screenDrawToolbarController = screenDrawToolbarController
        self.screenDrawCanvasController = screenDrawCanvasController
        self.recordingControlController = recordingControlController
        self.recordingRegionSelectionController = recordingRegionSelectionController
        self.recordingRegionIndicatorController = recordingRegionIndicatorController
        self.screenDrawHotkeyService = screenDrawHotkeyService
        self.pipHotkeyService = pipHotkeyService
        self.quickActionHotkeyService = quickActionHotkeyService
        self.recorder = ScreenRecorderEngine(cameraEngine: recordingCameraEngine)

        if self.screenDrawToolbarController.drawSessionStore !== self.screenDrawCanvasController.drawSessionStore {
            assertionFailure("Screen drawing toolbar and canvas must share the same session store")
        }

        self.screenDrawCanvasController.drawSessionStore.onSessionEvent = { [weak self] event in
            guard let self else { return }
            self.drawStatusMessage = event
        }

        self.screenDrawHotkeyService.onAction = { [weak self] action in
            self?.handleDrawHotkeyAction(action)
        }
        self.screenDrawHotkeyService.shouldHandleAction = { [weak self] action in
            self?.shouldHandleDrawHotkeyAction(action) ?? false
        }
        self.screenDrawHotkeyService.onRegistrationStatusChanged = { [weak self] isEnabled, message in
            guard let self else { return }
            self.isDrawGlobalHotkeysEnabled = isEnabled
            self.drawStatusMessage = message
        }
        self.pipHotkeyService.onAction = { [weak self] action in
            self?.handlePiPHotkeyAction(action)
        }
        self.pipHotkeyService.shouldHandleAction = { _ in true }
        self.pipHotkeyService.onRegistrationStatusChanged = { [weak self] isEnabled, _ in
            guard let self else { return }
            self.isPiPGlobalHotkeysEnabled = isEnabled
            self.pipStatusMessage = isEnabled
                ? L10n.tr(Self.pipHotkeyRegisteredStatusKey)
                : L10n.tr(Self.pipHotkeyFallbackStatusKey)
        }
        self.quickActionHotkeyService.onAction = { [weak self] action in
            self?.handleQuickActionHotkeyAction(action)
        }
        self.quickActionHotkeyService.shouldHandleAction = { _ in true }
        self.pipPreviewRuntime.onRecordingFailure = { [weak self] error in
            self?.handlePiPRecordingRuntimeFailure(error)
        }

        self.pipController.onVisibilityChanged = { [weak self] isVisible in
            guard let self else { return }
            if isVisible {
                self.isPiPPreviewVisible = true
                if !self.isPiPFilmRecording {
                    self.pipStatusMessage = L10n.tr("legacy.pip_6")
                }
            } else {
                self.isPiPPreviewVisible = false
                if self.isSuppressingPiPHideCallback {
                    self.isSuppressingPiPHideCallback = false
                    self.pipPreviewRuntime.stopPreview()
                } else if self.isPiPFilmRecording || self.isPiPFilmPreparing {
                    self.stopPiPFilmRecording(trigger: .close)
                } else {
                    self.pipPreviewRuntime.stopPreview()
                    self.pipStatusMessage = L10n.tr("legacy.pip_5")
                }
            }
            if self.recorderState.isRecording {
                Task { [weak self] in
                    guard let self else { return }
                    await self.syncPiPWindowCaptureState()
                }
            }
        }
        self.pipController.onCloseRequested = { [weak self] in
            guard let self else { return }
            if self.isPiPFilmRecording || self.isPiPFilmPreparing {
                self.stopPiPFilmRecording(trigger: .close)
            } else {
                self.pipLayout = self.pipController.currentLayoutState()
                self.pipController.hide()
            }
        }

        self.recordingControlController.onRecordToggleRequested = { [weak self] in
            self?.handleRecordingControlRecordToggle()
        }
        self.recordingControlController.onPauseToggleRequested = { [weak self] in
            self?.handleRecordingControlPauseToggle()
        }
        self.recordingControlController.onRegionToggleRequested = { [weak self] in
            self?.handleRecordingControlRegionToggle()
        }
        self.recordingControlController.onPiPToggleRequested = { [weak self] in
            self?.togglePiPPreviewFromRecordingControl()
        }
        self.recordingControlController.onAnnotateToggleRequested = { [weak self] in
            self?.toggleScreenDrawOverlayFromRecordingControl()
        }
        self.recordingControlController.onCloseRequested = { [weak self] in
            self?.handleRecordingControlCloseRequested()
        }

        self.screenDrawToolbarController.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.isDrawOverlayVisible = visible
            self.drawStatusMessage = visible ? L10n.tr("legacy.key_72") : L10n.tr("legacy.key_71")
            self.refreshRecordingWindowCaptureIfNeeded()
        }
        self.screenDrawToolbarController.onRequestClose = { [weak self] in
            self?.hideScreenDrawOverlay()
        }
        self.screenDrawToolbarController.onScreenRecoveryEvent = { [weak self] event in
            self?.handleDrawToolbarScreenRecoveryEvent(event)
        }
        self.screenDrawCanvasController.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            if !visible {
                self.isDrawOverlayVisible = false
                self.drawStatusMessage = L10n.tr("legacy.key_78")
            }
            self.refreshRecordingWindowCaptureIfNeeded()
        }
        self.screenDrawCanvasController.onRequestClose = { [weak self] in
            self?.hideScreenDrawOverlay()
        }
        self.screenDrawCanvasController.onScreenRecoveryEvent = { [weak self] event in
            self?.handleDrawCanvasScreenRecoveryEvent(event)
        }

        loadPersistedDrawDismissalAnimationPreferences()
        loadPersistedDrawAutoCaptureOnCloseEnabled()
        loadPersistedRecordingQualityConfig()
        loadPersistedAllRecordingEnabled()
        loadPersistedPiPRecordingQualityConfig()
        loadPersistedLanguageOption()
        resolveLanguage()
        bindState()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .demoFlowMenuBarCoordinatorReady,
                object: self
            )
        }
    }

    deinit {
        if let drawSystemDefinedMonitor {
            NSEvent.removeMonitor(drawSystemDefinedMonitor)
            self.drawSystemDefinedMonitor = nil
        }
        Task { @MainActor [screenDrawHotkeyService, pipHotkeyService, quickActionHotkeyService] in
            screenDrawHotkeyService.stop()
            pipHotkeyService.stop()
            quickActionHotkeyService.stop()
        }
    }

    var canStartRecording: Bool {
        !recorderState.isBusy
            && !recorderState.isRecording
            && !isRecordingArmed
            && !isRecordingPermissionRequestInFlight
            && !isRecordingRegionSelecting
    }

    var canStopRecording: Bool {
        (
            recorderState.isRecording
                || recorder.state.isRecording
                || recordingControlMode == .paused
        ) && recordingControlMode != .stopping
    }

    var isPiPFilmRecording: Bool {
        pipFilmState.isRecording
    }

    var isPiPFilmPreparing: Bool {
        if case .preparing = pipFilmState {
            return true
        }
        return false
    }

    var canStartPiPFilmRecording: Bool {
        !pipFilmState.isBusy && !pipFilmState.isRecording
    }

    var canStopPiPFilmRecording: Bool {
        pipFilmState.isRecording && !pipFilmState.isBusy
    }

    var drawHandDrawnIntensity: CGFloat {
        screenDrawCanvasController.drawSessionStore.handDrawnIntensity
    }

    var drawMarkStyle: ScreenDrawMarkStyle {
        screenDrawCanvasController.drawSessionStore.markStyle
    }

    var isAudioAuthorized: Bool {
        audioEngine.authorizationStatus == .authorized
    }

    var isCameraAuthorized: Bool {
        pipPreviewRuntime.authorizationStatus == .authorized
    }

    var appLocale: Locale {
        resolvedLanguage.locale
    }

    var isRegionRecordingEnabled: Bool { true }

    var recordingQualityWarningMessage: String? {
        switch recordingQualityConfig.customWarningLevel(for: currentRecordingNativeSize) {
        case .low:
            return L10n.tr("recording.quality.warning.low")
        case .high:
            return L10n.f(
                "recording.quality.warning.high",
                formattedRecordingQualityEstimatedSize
            )
        case nil:
            return nil
        }
    }

    var pipRecordingQualityWarningMessage: String? {
        switch pipRecordingQualityConfig.customWarningLevel() {
        case .low:
            return L10n.tr("pip.quality.warning.low")
        case .high:
            return L10n.tr("pip.quality.warning.high")
        case nil:
            return nil
        }
    }

    var pipRecordingQualityEstimatedTenMinuteSizeMB: Int {
        pipRecordingQualityConfig.estimatedTenMinuteSizeMB
    }

    var formattedRecordingQualityEstimatedSize: String {
        let sizeMB = recordingQualityConfig.estimatedTenMinuteSizeMB
        if sizeMB >= 1024 {
            let value = Double(sizeMB) / 1024.0
            return L10n.f("recording.quality.file_size.gb", value)
        }
        return L10n.f("recording.quality.file_size.mb", sizeMB)
    }

    var resolvedPrivacyPolicyURL: URL? {
        let base = Self.privacyPolicyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let baseURL = URL(string: base) else {
            return nil
        }
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        return baseURL.appendingPathComponent(privacyPolicyPathSuffix)
    }

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        NotificationCenter.default.post(name: .demoFlowMenuBarCoordinatorReady, object: self)
        audioEngine.refreshSources()
        pipPreviewRuntime.refreshSources()
        pipPreviewRuntime.refreshAudioSources()
        if isAudioAuthorized {
            audioEngine.startMonitoringIfNeeded()
        }
        pipController.applyWindowConfig(pipWindowConfig)
        pipPreviewRuntime.applyPreviewAudioConfig(pipAudioPreviewConfig)
        configureDrawHotkeysIfNeeded()
        configurePiPHotkeysIfNeeded()
        configureQuickActionHotkeysIfNeeded()
        refreshLanguageIfNeeded()
    }

    func evaluatePrivacyNoticeIfNeeded() {
        guard !hasEvaluatedPrivacyNoticeThisLaunch else { return }
        hasEvaluatedPrivacyNoticeThisLaunch = true
        guard !UserDefaults.standard.bool(forKey: Self.privacyNoticePresentedDefaultsKey) else {
            return
        }
        privacyPolicyOpenErrorMessage = nil
        isPrivacyNoticePresented = true
        // Mark as presented when the popup is shown once (not when user confirms).
        UserDefaults.standard.set(true, forKey: Self.privacyNoticePresentedDefaultsKey)
    }

    func dismissPrivacyNotice() {
        isPrivacyNoticePresented = false
    }

    func openPrivacyPolicyURL() {
        guard let url = resolvedPrivacyPolicyURL else {
            privacyPolicyOpenErrorMessage = L10n.tr("privacy.notice.url_invalid")
            return
        }
        let didOpen = NSWorkspace.shared.open(url)
        if didOpen {
            privacyPolicyOpenErrorMessage = nil
        } else {
            privacyPolicyOpenErrorMessage = L10n.tr("privacy.notice.open_failed")
        }
    }

    func refreshLanguageIfNeeded() {
        guard languageOption == .auto else { return }
        resolveLanguage()
    }

    func showPiPPreview(on screen: NSScreen? = nil) {
        guard enableCameraPiP else {
            pipStatusMessage = L10n.tr("legacy.pip_pip")
            print("[PiP] aborted: enableCameraPiP=false")
            return
        }
        guard isCameraAuthorized else {
            pipStatusMessage = L10n.tr("legacy.pip_23")
            print("[PiP] aborted: camera unauthorized")
            return
        }
        if pipPreviewRuntime.selectedSourceID == nil {
            pipPreviewRuntime.refreshSources()
        }
        guard pipPreviewRuntime.selectedSourceID != nil else {
            pipStatusMessage = L10n.tr("legacy.pip_26")
            print("[PiP] aborted: no selected camera after refresh")
            return
        }

        let targetScreen = screen
            ?? activeScreenByPointer()
            ?? NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else {
            print("[PiP] aborted: no target screen")
            return
        }
        print("[PiP] target screen visibleFrame=\(NSStringFromRect(targetScreen.visibleFrame))")

        pipStatusMessage = L10n.tr("legacy.pip_7")
        pipPreviewRuntime.applyPreviewAudioConfig(pipAudioPreviewConfig)
        pipPreviewRuntime.startPreviewIfNeeded()
        pipLayout.aspectRatio = pipAspectRatio
        let layout = PiPLayoutState(
            normalizedRect: pipLayout.normalizedRect,
            aspectRatio: pipAspectRatio
        )
        pipLayout = layout
        let didShow = pipController.show(session: pipPreviewRuntime.previewSession, on: targetScreen, layout: layout)
        print("[PiP] didShow=\(didShow) visible=\(pipController.isVisible)")
        if !didShow {
            pipStatusMessage = L10n.tr("legacy.pip_space")
        }
    }

    func activatePiPPreview(on screen: NSScreen? = nil) {
        if !enableCameraPiP {
            enableCameraPiP = true
        }
        DispatchQueue.main.async { [weak self] in
            self?.showPiPPreview(on: screen)
        }
        refreshRecordingWindowCaptureIfNeeded()
    }

    func hidePiPPreview() {
        if isPiPFilmRecording || isPiPFilmPreparing {
            stopPiPFilmRecording(trigger: .hide)
            return
        }
        pipLayout = pipController.currentLayoutState()
        pipController.hide()
        refreshRecordingWindowCaptureIfNeeded()
    }

    func startPiPFilmRecording() {
        guard canStartPiPFilmRecording else { return }
        pipFilmRecorder.resetFailureIfNeeded()
        pendingPiPFilmStopTrigger = nil
        pipFilmState = .preparing

        Task { [weak self] in
            guard let self else { return }
            do {
                let didShowPreview = await ensurePiPPreviewVisibleForFilmRecording()
                guard didShowPreview else {
                    throw PiPFilmRecorderServiceError.runtimeStartFailed(
                        L10n.tr("legacy.pip_space")
                    )
                }
                if let pendingStopTrigger = consumePendingPiPFilmStopTrigger() {
                    pipFilmState = .idle
                    pipController.applyRuntimeWindowTitleSuffix(nil)
                    if pendingStopTrigger != .manual {
                        performPiPHideAfterFilmStop()
                    }
                    return
                }
                let outputDirectory = try DemoFlowOutputDirectoryPolicy.preparePiPRecordingsDirectory()
                pipStatusMessage = L10n.tr("pip.film.status.preparing")
                try await pipFilmRecorder.startRecording(
                    with: pipPreviewRuntime,
                    outputDirectory: outputDirectory,
                    qualityConfig: pipRecordingQualityConfig
                )
                pipFilmState = pipFilmRecorder.state
                pipController.applyRuntimeWindowTitleSuffix(Self.pipFilmTitleRecordingSuffix)
                if let pendingStopTrigger = consumePendingPiPFilmStopTrigger() {
                    stopPiPFilmRecording(trigger: pendingStopTrigger)
                    return
                }
                pipStatusMessage = L10n.tr("pip.film.status.recording")
            } catch {
                if let pendingStopTrigger = consumePendingPiPFilmStopTrigger() {
                    pipFilmState = .idle
                    pipController.applyRuntimeWindowTitleSuffix(nil)
                    if pendingStopTrigger != .manual {
                        performPiPHideAfterFilmStop()
                    }
                    return
                }
                pipFilmState = pipFilmRecorder.state
                pipController.applyRuntimeWindowTitleSuffix(nil)
                pipStatusMessage = L10n.f("pip.film.status.failed", readablePiPFilmMessage(error))
            }
        }
    }

    func stopPiPFilmRecording(trigger: PiPFilmStopTrigger = .manual) {
        Task { [weak self] in
            guard let self else { return }
            if self.isPiPFilmPreparing {
                self.pendingPiPFilmStopTrigger = trigger
                self.pipStatusMessage = L10n.tr("pip.film.status.stopping")
                if trigger != .manual {
                    self.performPiPHideAfterFilmStop()
                }
                return
            }
            guard self.pipFilmState.isRecording else {
                if trigger != .manual {
                    self.performPiPHideAfterFilmStop()
                }
                return
            }
            self.pipStatusMessage = L10n.tr("pip.film.status.stopping")
            self.pipFilmState = .stopping
            do {
                let outputURL = try await self.pipFilmRecorder.stopRecording(with: self.pipPreviewRuntime)
                self.lastPiPFilmOutputURL = outputURL
                self.pipFilmState = self.pipFilmRecorder.state
                self.pipController.applyRuntimeWindowTitleSuffix(nil)
                if trigger == .manual {
                    self.pipStatusMessage = L10n.f("pip.film.status.saved", outputURL.lastPathComponent)
                } else {
                    self.performPiPHideAfterFilmStop()
                    self.pipStatusMessage = L10n.f("pip.film.status.saved", outputURL.lastPathComponent)
                }
            } catch {
                self.pipFilmState = self.pipFilmRecorder.state
                self.pipController.applyRuntimeWindowTitleSuffix(nil)
                self.pipStatusMessage = L10n.f("pip.film.status.failed", self.readablePiPFilmMessage(error))
                if trigger != .manual {
                    self.performPiPHideAfterFilmStop()
                }
            }
        }
    }

    func openPiPRecordingsDirectory() {
        do {
            let directory = try DemoFlowOutputDirectoryPolicy.preparePiPRecordingsDirectory()
            if let lastPiPFilmOutputURL {
                NSWorkspace.shared.activateFileViewerSelecting([lastPiPFilmOutputURL])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        } catch {
            pipStatusMessage = L10n.f("pip.film.status.failed", readablePiPFilmMessage(error))
        }
    }

    func showScreenDrawOverlay() {
        guard !isDrawOverlayVisible else { return }
        let targetScreen = activeScreenByPointer()
            ?? NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let didShowCanvas = screenDrawCanvasController.show(on: targetScreen)
        if didShowCanvas {
            setDrawCanvasInteractionEnabled(true)
            screenDrawToolbarController.show(on: targetScreen)
            isDrawOverlayVisible = true
            refreshRecordingWindowCaptureIfNeeded()
            drawStatusMessage = L10n.tr("legacy.key_70")
        } else {
            isDrawOverlayVisible = false
            screenDrawToolbarController.hide()
            drawStatusMessage = L10n.tr("legacy.key_76")
        }
    }

    func hideScreenDrawOverlay() {
        pendingDrawCaptureRefreshTask?.cancel()
        pendingDrawCaptureRefreshTask = nil
        let shouldAutoCapture = isDrawAutoCaptureOnCloseEnabled
        let targetScreen = screenDrawCanvasController.currentScreen
            ?? activeScreenByPointer()
            ?? NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let captureCanvasImage = shouldAutoCapture
            ? (screenDrawCanvasController.snapshotImage() ?? makeTransparentCanvasImage(for: targetScreen))
            : nil
        screenDrawToolbarController.hide()
        if screenDrawCanvasController.hasDrawableContent {
            drawStatusMessage = L10n.tr("draw.dismiss.start")
        }
        screenDrawCanvasController.hideWithDismissalAnimation { [weak self] in
            guard let self else { return }
            self.isDrawOverlayVisible = false
            if shouldAutoCapture {
                self.captureScreenDrawCompositeIfNeeded(
                    screen: targetScreen,
                    canvasImage: captureCanvasImage
                )
            } else {
                self.drawStatusMessage = L10n.tr("legacy.key_69")
            }
            self.refreshRecordingWindowCaptureIfNeeded()
        }
    }

    func clearScreenDrawCanvas() {
        if screenDrawCanvasController.hasDrawableContent {
            drawStatusMessage = L10n.tr("draw.dismiss.start")
        }
        screenDrawCanvasController.clearCanvasWithDismissalAnimation { [weak self] in
            self?.refreshRecordingWindowCaptureIfNeeded()
        }
    }

    func setDrawHandDrawnIntensity(_ value: CGFloat) {
        let clamped = max(0, min(value, 1))
        screenDrawCanvasController.drawSessionStore.handDrawnIntensity = clamped
        drawStatusMessage = L10n.f("fmt.draw.intensity", Int(clamped * 100))
    }

    func setDrawMarkStyle(_ style: ScreenDrawMarkStyle) {
        screenDrawCanvasController.drawSessionStore.markStyle = style
        drawStatusMessage = L10n.f("fmt.draw.mark_style_changed", style.title)
    }

    func openScreenDrawAutoCaptureDirectory() {
        do {
            let directory = try DemoFlowOutputDirectoryPolicy.prepareScreenDrawAutoCaptureDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            drawStatusMessage = L10n.f("fmt.draw.capture_failed", error.localizedDescription)
        }
    }

    // Compatibility wrappers for existing callers.
    func showScreenDrawingOverlay() {
        showScreenDrawOverlay()
    }

    func hideScreenDrawingOverlay() {
        hideScreenDrawOverlay()
    }

    func endScreenDrawingSession() {
        screenDrawCanvasController.drawSessionStore.resetForNewSession()
        hideScreenDrawOverlay()
        drawStatusMessage = L10n.tr("legacy.key_67")
    }

    func startRecordingFromCurrentConfig(preferredScreen: NSScreen? = nil) {
        guard canStartRecording else {
            statusMessage = unavailableReason()
            return
        }
        runRecordingPermissionRequest {
            self.presentRecordingStartControl(
                preferredScreen: preferredScreen,
                captureMode: self.effectiveRecordingCaptureMode
            )
        }
    }

    func startRecordingImmediatelyFromMenuBar(preferredScreen: NSScreen? = nil) {
        guard canStartRecording else {
            statusMessage = unavailableReason()
            return
        }
        runRecordingPermissionRequest {
            self.presentRecordingStartControl(
                preferredScreen: preferredScreen,
                captureMode: .fullScreen
            )
            await self.startRecordingSegmentForCurrentSession()
        }
    }

    private func presentRecordingStartControl(
        preferredScreen: NSScreen? = nil,
        captureMode: RecordingCaptureMode
    ) {
        guard canStartRecording else {
            statusMessage = unavailableReason()
            return
        }
        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first
        if recordingCaptureMode != captureMode {
            recordingCaptureMode = captureMode
        }
        resetRecordingSessionForArming(captureMode: captureMode)
        isRecordingArmed = true
        armedRecordingCaptureMode = captureMode
        recordingControlMode = .ready
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        recordingControlController.show(on: screen)
        startRecordingControlSizeRefreshTimerIfNeeded()
        if captureMode == .region {
            if let fixedPreset = recordingFixedCapturePreset {
                applyFixedCapturePresetSelection(fixedPreset, preferredScreen: screen)
            }
            guard beginRegionSelectionIfNeededForReadyControl(preferredScreen: screen) else {
                isRecordingArmed = false
                recordingControlController.hide()
                statusMessage = L10n.tr("recording.region.error.display_unavailable")
                return
            }
            statusMessage = L10n.tr("recording.region.status.selecting")
        } else {
            dismissRegionSelectionOverlay()
            refreshRecordingControlSizeDisplayForCurrentMode()
            statusMessage = L10n.tr("legacy.key_176")
        }
    }

    func stopRecordingAndRestoreMonitoring() {
        handleRecordingControlCloseRequested()
    }

    private func runRecordingPermissionRequest(
        onDenied: (@MainActor () -> Void)? = nil,
        onGranted: @escaping @MainActor () async -> Void
    ) {
        isRecordingPermissionRequestInFlight = true
        statusMessage = L10n.tr("legacy.key_21")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.requestScreenRecordingAccessIfNeeded() else {
                self.isRecordingPermissionRequestInFlight = false
                self.statusMessage = L10n.tr("legacy.demoflow_7")
                onDenied?()
                return
            }
            self.isRecordingPermissionRequestInFlight = false
            await onGranted()
        }
    }

    private var effectiveRecordingCaptureMode: RecordingCaptureMode {
        if recordingFixedCapturePreset != nil {
            return .region
        }
        return recordingCaptureMode
    }

    func setRecordingCaptureMode(_ mode: RecordingCaptureMode) {
        guard recordingCaptureMode != mode else { return }
        recordingCaptureMode = mode
        armedRecordingCaptureMode = mode
        if mode == .fullScreen {
            recordingFixedCapturePreset = nil
            recordingRegionSelectionController.setSelectionInteractionMode(.freeform)
            dismissRegionSelectionOverlay()
            statusMessage = L10n.tr("legacy.key_115")
            if isRecordingArmed || recordingControlController.isVisible {
                refreshRecordingControlSizeDisplayForCurrentMode()
            }
            return
        }

        dismissRegionSelectionOverlay()
        let interactionMode: RecordingRegionSelectionInteractionMode = recordingFixedCapturePreset == nil ? .freeform : .fixedSizeLocked
        recordingRegionSelectionController.setSelectionInteractionMode(interactionMode)
        if let pendingRegionSelection {
            updateRecordingRegionSelectionSizeText(from: pendingRegionSelection)
            statusMessage = L10n.tr("recording.region.status.confirmed")
        } else {
            recordingRegionSelectionSizeText = "400 x 400"
            statusMessage = L10n.tr("recording.region.status.selecting")
        }
        if isRecordingArmed || recordingControlController.isVisible {
            _ = beginRegionSelectionIfNeededForReadyControl(preferredScreen: nil)
            refreshRecordingControlSizeDisplayForCurrentMode()
        }
    }

    func toggleRecordingFixedCapturePreset(_ preset: RecordingFixedCapturePreset) {
        guard !recorderState.isRecording, !recorderState.isBusy else { return }
        if recordingFixedCapturePreset == preset {
            recordingFixedCapturePreset = nil
            recordingRegionSelectionController.setSelectionInteractionMode(.freeform)
            if recordingCaptureMode == .region,
               (isRecordingArmed || recordingControlController.isVisible || isRecordingRegionSelecting) {
                _ = beginRegionSelectionIfNeededForReadyControl(preferredScreen: nil)
                refreshRecordingControlSizeDisplayForCurrentMode()
            }
            return
        }

        recordingFixedCapturePreset = preset
        if recordingCaptureMode == .region,
           (isRecordingArmed || recordingControlController.isVisible || isRecordingRegionSelecting) {
            recordingRegionSelectionController.setSelectionInteractionMode(.fixedSizeLocked)
            let preferredScreen = activeScreenByPointer() ?? NSScreen.main ?? NSScreen.screens.first
            applyFixedCapturePresetSelection(
                preset,
                preferredScreen: preferredScreen
            )
            if isRecordingRegionSelecting {
                dismissRegionSelectionOverlay()
            }
            if beginRegionSelectionIfNeededForReadyControl(preferredScreen: preferredScreen) {
                refreshRecordingControlSizeDisplayForCurrentMode()
            } else {
                statusMessage = L10n.tr("recording.region.error.display_unavailable")
            }
            updateRecordingControlDisplayModel()
            updateRecordingControlSurface()
            if statusMessage != L10n.tr("recording.region.error.display_unavailable") {
                statusMessage = L10n.tr("recording.region.status.confirmed")
            }
        }
    }

    @discardableResult
    private func beginRegionSelectionIfNeededForReadyControl(preferredScreen: NSScreen?) -> Bool {
        if isRecordingRegionSelecting {
            return true
        }
        let screen = preferredScreen
            ?? activeScreenByPointer()
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen, screen.displayID != nil else {
            return false
        }
        if let fixedPreset = recordingFixedCapturePreset {
            applyFixedCapturePresetSelection(fixedPreset, preferredScreen: screen)
        }
        recordingRegionSelectionController.setSelectionInteractionMode(
            recordingFixedCapturePreset == nil ? .freeform : .fixedSizeLocked
        )

        isRecordingRegionSelecting = true
        recordingRegionSelectionController.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            self.pendingRegionSelection = selection
            self.updateRecordingRegionSelectionSizeText(from: selection)
            self.refreshRecordingControlSizeDisplayForCurrentMode()
        }

        let didPresent = recordingRegionSelectionController.present(
            on: screen,
            initialSelection: pendingRegionSelection
        ) { [weak self] result in
            guard let self else { return }
            self.isRecordingRegionSelecting = false
            self.recordingRegionSelectionController.onSelectionChanged = nil

            switch result {
            case .cancelled:
                self.statusMessage = L10n.tr("recording.region.status.cancelled")
                if self.isRecordingArmed,
                   self.recordingControlMode == .ready,
                   !self.recorderState.isRecording {
                    self.isRecordingArmed = false
                    self.recordingControlController.hide()
                    self.recordingRegionIndicatorController.hide()
                    self.resetRecordingSessionStateForIdle()
                }
            case let .confirmed(selection):
                guard selection.rectInDisplayPoints.width >= 2,
                      selection.rectInDisplayPoints.height >= 2 else {
                    self.statusMessage = L10n.tr("recording.region.error.invalid_region")
                    return
                }
                self.pendingRegionSelection = selection
                self.updateRecordingRegionSelectionSizeText(from: selection)
                self.refreshRecordingControlSizeDisplayForCurrentMode()
                self.statusMessage = L10n.tr("recording.region.status.confirmed")
            }
        }

        if !didPresent {
            isRecordingRegionSelecting = false
            recordingRegionSelectionController.onSelectionChanged = nil
            return false
        }
        if didPresent, let liveSelection = recordingRegionSelectionController.currentSelection {
            pendingRegionSelection = liveSelection
            updateRecordingRegionSelectionSizeText(from: liveSelection)
            refreshRecordingControlSizeDisplayForCurrentMode()
        }
        return true
    }

    private func applyFixedCapturePresetSelection(
        _ preset: RecordingFixedCapturePreset,
        preferredScreen: NSScreen?
    ) {
        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first,
              let displayID = screen.displayID else {
            return
        }
        let rect = fixedCaptureRectInPoints(for: preset, on: screen)
        let selection = RecordingRegionSelection(
            displayID: displayID,
            rectInDisplayPoints: rect
        )
        pendingRegionSelection = selection
        updateRecordingRegionSelectionSizeText(from: selection)
    }

    private func fixedCaptureRectInPoints(
        for preset: RecordingFixedCapturePreset,
        on screen: NSScreen
    ) -> CGRect {
        let screenSize = screen.frame.size
        let scale = max(screen.backingScaleFactor, 1)
        let targetPixelSize = preset.pixelSize
        var targetPointSize = CGSize(
            width: targetPixelSize.width / scale,
            height: targetPixelSize.height / scale
        )
        if targetPointSize.width > screenSize.width || targetPointSize.height > screenSize.height {
            let fitScale = min(
                screenSize.width / max(targetPointSize.width, 1),
                screenSize.height / max(targetPointSize.height, 1)
            )
            targetPointSize = CGSize(
                width: targetPointSize.width * fitScale,
                height: targetPointSize.height * fitScale
            )
        }

        let origin = CGPoint(
            x: max(0, (screenSize.width - targetPointSize.width) / 2),
            y: max(0, (screenSize.height - targetPointSize.height) / 2)
        )
        return CGRect(origin: origin, size: targetPointSize).integral
    }

    private func dismissRegionSelectionOverlay() {
        if isRecordingRegionSelecting {
            recordingRegionSelectionController.dismiss()
            recordingRegionSelectionController.onSelectionChanged = nil
            isRecordingRegionSelecting = false
        } else {
            recordingRegionSelectionController.onSelectionChanged = nil
        }
    }

    private func refreshRecordingControlSizeDisplayForCurrentMode() {
        let modeForPreview = recordingCaptureMode
        let sizeText: String = {
            if let locked = recordingSessionLockedCaptureSizeDisplay {
                return locked
            }
            switch modeForPreview {
            case .fullScreen:
                return formattedCurrentScreenSizeDisplay() ?? "-- x --"
            case .region:
                if let activeRecordingRegionSelection {
                    return sizeDisplayForRegionSelection(activeRecordingRegionSelection)
                }
                if let pendingRegionSelection {
                    return sizeDisplayForRegionSelection(pendingRegionSelection)
                }
                if let recordingFixedCapturePreset {
                    return recordingFixedCapturePreset.displayText
                }
                return recordingRegionSelectionSizeText
            }
        }()
        recordingControlDisplayModel.captureSizeDisplay = sizeText
        updateRecordingControlSurface()
    }

    private func updateRecordingRegionSelectionSizeText(from selection: RecordingRegionSelection) {
        recordingRegionSelectionSizeText = sizeDisplayForRegionSelection(selection)
    }

    private func sizeDisplayForRegionSelection(_ selection: RecordingRegionSelection) -> String {
        guard recordingFixedCapturePreset != nil else {
            return formatSizeDisplay(for: selection.rectInDisplayPoints.size)
        }
        guard let screen = NSScreen.screen(with: selection.displayID) else {
            return formatSizeDisplay(for: selection.rectInDisplayPoints.size)
        }
        let scale = max(screen.backingScaleFactor, 1)
        let pixelSize = CGSize(
            width: selection.rectInDisplayPoints.width * scale,
            height: selection.rectInDisplayPoints.height * scale
        )
        return formatSizeDisplay(for: pixelSize)
    }

    private func bindState() {
        pipPreviewRuntime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        audioEngine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        recorder.$statusMessage
            .receive(on: RunLoop.main)
            .assign(to: &$statusMessage)

        recorder.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] nextState in
                self?.recorderState = nextState
                self?.syncRecordingUI(for: nextState)
            }
            .store(in: &cancellables)

        pipController.$layoutState
            .receive(on: RunLoop.main)
            .sink { [weak self] layout in
                self?.pipLayout = layout
                if self?.pipAspectRatio != layout.aspectRatio {
                    self?.pipAspectRatio = layout.aspectRatio
                }
            }
            .store(in: &cancellables)

        pipFilmRecorder.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.pipFilmState = state
            }
            .store(in: &cancellables)

        pipFilmRecorder.$lastOutputURL
            .receive(on: RunLoop.main)
            .sink { [weak self] url in
                self?.lastPiPFilmOutputURL = url
            }
            .store(in: &cancellables)
    }

    private func unavailableReason() -> String {
        L10n.tr("legacy.key_107")
    }

    private func readablePiPFilmMessage(_ error: Error) -> String {
        let localized = (error as NSError).localizedDescription
        if !localized.isEmpty {
            return localized
        }
        return L10n.tr("pip.film.error.unknown")
    }

    private func handlePiPRecordingRuntimeFailure(_ error: Error) {
        pipFilmRecorder.handleRuntimeFailure(error)
        pendingPiPFilmStopTrigger = nil
        pipController.applyRuntimeWindowTitleSuffix(nil)
        pipStatusMessage = L10n.f("pip.film.status.failed", readablePiPFilmMessage(error))
    }

    private func consumePendingPiPFilmStopTrigger() -> PiPFilmStopTrigger? {
        let trigger = pendingPiPFilmStopTrigger
        pendingPiPFilmStopTrigger = nil
        return trigger
    }

    private func performPiPHideAfterFilmStop() {
        pipLayout = pipController.currentLayoutState()
        isSuppressingPiPHideCallback = true
        pipController.hide()
        refreshRecordingWindowCaptureIfNeeded()
    }

    private func ensurePiPPreviewVisibleForFilmRecording() async -> Bool {
        if isPiPPreviewVisible {
            return true
        }
        activatePiPPreview()
        for _ in 0..<12 {
            if isPiPPreviewVisible {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isPiPPreviewVisible
    }

    private func hideMainWindowForRecording() {
        for window in NSApp.windows where !(window is NSPanel) {
            window.orderOut(nil)
        }
    }

    private func restoreMainWindowAfterRecording() {
        guard shouldRestoreMainWindowAfterRecording else { return }
        shouldRestoreMainWindowAfterRecording = false
        recordingControlController.hide()
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openAppSettingsFromMenuBar() {
        selectedSettingsSection = .recording
        showMainWindow()
    }

    func toggleRecordingFromMenuBar() {
        if canStopRecording {
            stopRecordingAndRestoreMonitoring()
        } else if canStartRecording {
            startRecordingImmediatelyFromMenuBar()
        }
    }

    func togglePiPPreviewFromMenuBar() {
        if isPiPPreviewVisible {
            hidePiPPreview()
            pipStatusMessage = L10n.tr("pip.hotkey.hidden")
        } else {
            activatePiPPreview()
            pipStatusMessage = L10n.tr("pip.hotkey.showing")
        }
        refreshRecordingWindowCaptureIfNeeded()
    }

    func togglePiPRecordingFromMenuBar() {
        if canStopPiPFilmRecording || isPiPFilmPreparing {
            stopPiPFilmRecording()
        } else if canStartPiPFilmRecording {
            startPiPFilmRecording()
        }
    }

    func toggleScreenDrawOverlayFromMenuBar() {
        if isDrawOverlayVisible {
            hideScreenDrawOverlay()
            drawStatusMessage = L10n.tr("legacy.key_74")
        } else {
            showScreenDrawOverlay()
            drawStatusMessage = L10n.tr("legacy.key_73")
        }
    }

    private func syncRecordingUI(for state: RecordingState) {
        switch state {
        case .recording:
            isRecordingArmed = false
            hideMainWindowForRecording()
            recordingControlMode = .recording
            updateRecordingControlDisplayModel()
            updateRecordingControlSurface()
            let screen = NSScreen.main ?? NSScreen.screens.first
            recordingControlController.show(on: screen)
            if let activeRecordingRegionSelection {
                _ = recordingRegionIndicatorController.show(selection: activeRecordingRegionSelection)
            } else {
                recordingRegionIndicatorController.hide()
            }
            refreshRecordingWindowCaptureIfNeeded()
        case .idle:
            if recordingSessionStopIntent != .none || recordingControlMode == .paused {
                return
            }
            isRecordingArmed = false
            stopRecordingSessionTimer()
            recordingControlMode = .ready
            recordingControlController.hide()
            stopRecordingControlSizeRefreshTimer()
            recordingRegionIndicatorController.hide()
            dismissRegionSelectionOverlay()
            activeRecordingRegionSelection = nil
            recordingSessionLockedCaptureSizeDisplay = nil
            restoreMainWindowAfterRecording()
        case .failed:
            if recordingSessionStopIntent != .none || recordingControlMode == .paused {
                return
            }
            isRecordingArmed = false
            stopRecordingSessionTimer()
            recordingControlMode = .ready
            recordingControlController.hide()
            stopRecordingControlSizeRefreshTimer()
            recordingRegionIndicatorController.hide()
            dismissRegionSelectionOverlay()
            activeRecordingRegionSelection = nil
            recordingSessionLockedCaptureSizeDisplay = nil
            restoreMainWindowAfterRecording()
            if isAudioAuthorized {
                audioEngine.startMonitoringIfNeeded()
            }
        case .preparing, .stopping:
            break
        }
    }

    @discardableResult
    private func syncPiPWindowCaptureState() async -> Bool {
        guard recorderState.isRecording else { return true }
        let pipWindowID = pipController.currentWindowID
        let resolution = await recorder.updatePiPWindowCapture(
            windowID: pipWindowID,
            extraWindowIDs: screenDrawWhitelistWindowIDs()
        )
        return resolution.didIncludeAllRequestedWindows
    }

    private func handleRecordingControlRecordToggle() {
        switch recordingControlMode {
        case .ready:
            guard isRecordingArmed else {
                statusMessage = unavailableReason()
                return
            }
            guard !recorderState.isBusy, !recorderState.isRecording else {
                statusMessage = unavailableReason()
                return
            }
            if armedRecordingCaptureMode == .region {
                if let liveSelection = recordingRegionSelectionController.currentSelection {
                    pendingRegionSelection = liveSelection
                    updateRecordingRegionSelectionSizeText(from: liveSelection)
                }
                guard let pendingRegionSelection,
                      NSScreen.screen(with: pendingRegionSelection.displayID) != nil else {
                    let didPresent = beginRegionSelectionIfNeededForReadyControl(preferredScreen: nil)
                    if !didPresent {
                        statusMessage = L10n.tr("recording.region.error.display_unavailable")
                    } else {
                        statusMessage = L10n.tr("recording.region.status.selecting")
                    }
                    return
                }
            }
            runRecordingPermissionRequest(
                onDenied: {
                    self.recordingControlMode = .ready
                    self.updateRecordingControlDisplayModel()
                    self.updateRecordingControlSurface()
                },
                onGranted: {
                    await self.startRecordingSegmentForCurrentSession()
                }
            )
        case .recording:
            Task { @MainActor [weak self] in
                await self?.stopRecordingSessionAndFinalize(closeControlAfterStop: true)
            }
        case .paused:
            Task { @MainActor [weak self] in
                await self?.resumeRecordingSessionSegment()
            }
        case .stopping:
            break
        }
    }

    private func handleRecordingControlPauseToggle() {
        switch recordingControlMode {
        case .recording:
            Task { @MainActor [weak self] in
                await self?.pauseRecordingSessionSegment()
            }
        case .paused:
            Task { @MainActor [weak self] in
                await self?.resumeRecordingSessionSegment()
            }
        case .ready, .stopping:
            break
        }
    }

    private func handleRecordingControlRegionToggle() {
        guard recordingControlMode == .ready else { return }
        guard !recorderState.isRecording, !recorderState.isBusy else { return }
        let nextMode: RecordingCaptureMode = (recordingCaptureMode == .region) ? .fullScreen : .region
        setRecordingCaptureMode(nextMode)
        if nextMode == .region {
            _ = beginRegionSelectionIfNeededForReadyControl(preferredScreen: nil)
        }
        refreshRecordingControlSizeDisplayForCurrentMode()
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
    }

    private func handleRecordingControlCloseRequested() {
        switch recordingControlMode {
        case .recording, .paused:
            Task { @MainActor [weak self] in
                await self?.stopRecordingSessionAndFinalize(closeControlAfterStop: true)
            }
        case .ready:
            isRecordingArmed = false
            dismissRegionSelectionOverlay()
            recordingRegionIndicatorController.hide()
            recordingControlController.hide()
            stopRecordingControlSizeRefreshTimer()
            resetRecordingSessionStateForIdle()
            statusMessage = L10n.tr("recording.region.status.cancelled")
            if isAudioAuthorized {
                audioEngine.startMonitoringIfNeeded()
            }
            restoreMainWindowAfterRecording()
        case .stopping:
            break
        }
    }

    private func toggleScreenDrawOverlayFromRecordingControl() {
        toggleScreenDrawOverlayFromMenuBar()
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        if recorderState.isRecording {
            refreshRecordingWindowCaptureIfNeeded()
        }
    }

    private func togglePiPPreviewFromRecordingControl() {
        if isPiPPreviewVisible {
            hidePiPPreview()
        } else {
            activatePiPPreview()
        }
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        if recorderState.isRecording {
            refreshRecordingWindowCaptureIfNeeded()
        }
    }

    private func startRecordingSegmentForCurrentSession() async {
        guard !recorderState.isBusy, !recorderState.isRecording else {
            statusMessage = unavailableReason()
            return
        }

        let captureMode = armedRecordingCaptureMode
        let regionSelection: RecordingRegionSelection? = {
            guard captureMode == .region else { return nil }
            if let liveSelection = recordingRegionSelectionController.currentSelection {
                pendingRegionSelection = liveSelection
                updateRecordingRegionSelectionSizeText(from: liveSelection)
            }
            return pendingRegionSelection
        }()

        if captureMode == .region {
            guard let regionSelection,
                  NSScreen.screen(with: regionSelection.displayID) != nil else {
                statusMessage = L10n.tr("recording.region.error.invalid_region")
                return
            }
            activeRecordingRegionSelection = regionSelection
            recordingSessionLockedCaptureSizeDisplay = formatSizeDisplay(for: regionSelection.rectInDisplayPoints.size)
            dismissRegionSelectionOverlay()
            _ = recordingRegionIndicatorController.show(selection: regionSelection)
        } else {
            activeRecordingRegionSelection = nil
            recordingSessionLockedCaptureSizeDisplay = formattedCurrentScreenSizeDisplay()
            dismissRegionSelectionOverlay()
            recordingRegionIndicatorController.hide()
        }

        audioEngine.stopMonitoring()
        pipLayout.aspectRatio = pipAspectRatio
        shouldRestoreMainWindowAfterRecording = !isAllRecordingEnabled
        if !isAllRecordingEnabled {
            hideMainWindowForRecording()
        }
        recordingControlMode = .recording
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()

        let request = buildRecordingRequest(
            captureMode: captureMode,
            regionSelection: activeRecordingRegionSelection
        )
        let screen = NSScreen.main ?? NSScreen.screens.first
        await recorder.startRecording(request: request, preferredScreen: screen)
        if recorder.state.isRecording {
            recordingControlMode = .recording
            isRecordingArmed = false
            recordingControlController.show(on: screen)
            updateRecordingControlDisplayModel()
            updateRecordingControlSurface()
            if recordingSessionCurrentSegmentStart == nil {
                recordingSessionCurrentSegmentStart = Date()
                startRecordingSessionTimer()
            }
            refreshRecordingWindowCaptureIfNeeded()
        } else {
            recordingControlMode = .ready
            updateRecordingControlDisplayModel()
            updateRecordingControlSurface()
            if case .failed = recorder.state,
               !statusMessage.contains(L10n.tr("legacy.key_65")),
               !statusMessage.contains(L10n.tr("legacy.key_37")) {
                statusMessage = L10n.tr("legacy.demoflow_2")
            }
            activeRecordingRegionSelection = nil
            recordingSessionLockedCaptureSizeDisplay = nil
            if isAudioAuthorized {
                audioEngine.startMonitoringIfNeeded()
            }
            restoreMainWindowAfterRecording()
        }
    }

    private func pauseRecordingSessionSegment() async {
        guard recordingControlMode == .recording else { return }
        guard recorderState.isRecording else { return }
        let previousMode = recordingControlMode
        recordingSessionStopIntent = .pause
        recordingControlMode = .stopping
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        statusMessage = L10n.tr("legacy.key_169")

        await recorder.stopRecording(reason: .pause)
        guard case .idle = recorder.state, let artifact = recorder.lastArtifact else {
            recordingSessionStopIntent = .none
            recordingControlMode = previousMode
            updateRecordingControlDisplayModel()
            updateRecordingControlSurface()
            if isAudioAuthorized {
                audioEngine.startMonitoringIfNeeded()
            }
            return
        }

        recordingSessionSegmentURLs.append(artifact.mergedURL)
        let elapsed = currentRecordingElapsedSeconds()
        recordingSessionElapsedBeforeCurrentSegment = elapsed
        recordingSessionCurrentSegmentStart = nil
        stopRecordingSessionTimer()
        recordingControlMode = .paused
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        let screen = NSScreen.main ?? NSScreen.screens.first
        recordingControlController.show(on: screen)
        statusMessage = L10n.tr("recording.control.status.paused")
        if isAudioAuthorized {
            audioEngine.startMonitoringIfNeeded()
        }
    }

    private func resumeRecordingSessionSegment() async {
        guard recordingControlMode == .paused else { return }
        guard !recorderState.isBusy, !recorderState.isRecording else { return }
        recordingSessionStopIntent = .none
        recordingControlMode = .ready
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        await startRecordingSegmentForCurrentSession()
    }

    private func stopRecordingSessionAndFinalize(closeControlAfterStop: Bool) async {
        guard recordingControlMode != .stopping else { return }
        recordingSessionStopIntent = .finalize
        recordingControlMode = .stopping
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
        statusMessage = L10n.tr("legacy.key_169")
        var finalizedOutputURL: URL?

        if recorderState.isRecording {
            await recorder.stopRecording(reason: .finalize)
            if case .idle = recorder.state, let artifact = recorder.lastArtifact {
                recordingSessionSegmentURLs.append(artifact.mergedURL)
            }
        }

        do {
            let finalURL = try await finalizeRecordingOutputIfNeeded()
            recorder.applyPostProcessedOutputURL(finalURL)
            finalizedOutputURL = finalURL
            statusMessage = L10n.tr("legacy.key_109")
        } catch {
            statusMessage = L10n.f("fmt.recording.stop_failed", error.localizedDescription)
        }

        pipLayout = pipController.currentLayoutState()
        recordingRegionIndicatorController.hide()
        dismissRegionSelectionOverlay()
        if closeControlAfterStop {
            recordingControlController.hide()
        }
        stopRecordingControlSizeRefreshTimer()
        recordingSessionStopIntent = .none
        resetRecordingSessionStateForIdle()
        if isAudioAuthorized {
            audioEngine.startMonitoringIfNeeded()
        }
        restoreMainWindowAfterRecording()
        if let finalizedOutputURL {
            NotificationCenter.default.post(
                name: .demoFlowRecordingDidFinalizeOutput,
                object: finalizedOutputURL
            )
        }
    }

    private func finalizeRecordingOutputIfNeeded() async throws -> URL {
        if recordingSessionSegmentURLs.isEmpty {
            if let output = recorder.lastOutputURL {
                return output
            }
            throw NSError(
                domain: "DemoFlow.Recording",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("recording.control.error.no_segments")]
            )
        }
        if recordingSessionSegmentURLs.count == 1 {
            return recordingSessionSegmentURLs[0]
        }

        let baseURL = recordingSessionSegmentURLs[0]
        var accumulatedSeconds = await normalizedDurationSeconds(for: baseURL) ?? 0
        var layers: [CompositionLayer] = []
        for url in recordingSessionSegmentURLs.dropFirst() {
            layers.append(
                CompositionLayer(
                    assetURL: url,
                    insertTime: CMTime(seconds: max(0, accumulatedSeconds), preferredTimescale: 600),
                    mute: false
                )
            )
            accumulatedSeconds += await normalizedDurationSeconds(for: url) ?? 0
        }
        let project = CompositionProject(baseAssetURL: baseURL, layers: layers)
        let outputURL = try makeSegmentMergedURL()
        let finalURL = try await compositionEngine.stitch(project: project, outputURL: outputURL)
        cleanupRecordingSessionSegments(except: finalURL)
        return finalURL
    }

    private func buildRecordingRequest(
        captureMode: RecordingCaptureMode,
        regionSelection: RecordingRegionSelection?
    ) -> RecordingRequest {
        let shouldCaptureMicrophone = isAudioAuthorized
            && audioEngine.selectedSourceID != nil
        return RecordingRequest(
            captureMode: captureMode,
            regionSelection: regionSelection,
            includeAppWindowsInCapture: isAllRecordingEnabled,
            microphoneDeviceID: shouldCaptureMicrophone ? audioEngine.selectedSourceID : nil,
            cameraDeviceID: nil,
            cameraAudioDeviceID: nil,
            recordingQuality: recordingQualityConfig,
            pipWindowID: pipController.currentWindowID,
            screenDrawWindowIDs: screenDrawWhitelistWindowIDs(),
            pipLayout: pipLayout,
            pipAspectRatio: pipAspectRatio,
            pipProcessingConfig: pipProcessingConfig,
            pipAudioPreviewConfig: pipAudioPreviewConfig
        )
    }

    private func resetRecordingSessionForArming(captureMode: RecordingCaptureMode) {
        recordingSessionSegmentURLs = []
        recordingSessionElapsedBeforeCurrentSegment = 0
        recordingSessionCurrentSegmentStart = nil
        stopRecordingSessionTimer()
        recordingSessionLockedCaptureSizeDisplay = nil
        recordingSessionStopIntent = .none
        recordingControlMode = .ready
        recordingControlDisplayModel = .default
        recordingControlDisplayModel.isAnnotateActive = isDrawOverlayVisible
        armedRecordingCaptureMode = captureMode
        if captureMode == .region {
            recordingControlDisplayModel.captureSizeDisplay = pendingRegionSelection.map {
                formatSizeDisplay(for: $0.rectInDisplayPoints.size)
            } ?? recordingRegionSelectionSizeText
        } else {
            recordingControlDisplayModel.captureSizeDisplay = formattedCurrentScreenSizeDisplay() ?? "-- x --"
        }
        updateRecordingControlDisplayModel()
    }

    private func resetRecordingSessionStateForIdle() {
        recordingSessionSegmentURLs = []
        recordingSessionElapsedBeforeCurrentSegment = 0
        recordingSessionCurrentSegmentStart = nil
        stopRecordingSessionTimer()
        stopRecordingControlSizeRefreshTimer()
        recordingSessionLockedCaptureSizeDisplay = nil
        recordingSessionStopIntent = .none
        recordingControlMode = .ready
        activeRecordingRegionSelection = nil
        updateRecordingControlDisplayModel()
        updateRecordingControlSurface()
    }

    private func updateRecordingControlDisplayModel() {
        let elapsed = formatElapsedDisplay(currentRecordingElapsedSeconds())
        recordingControlDisplayModel.elapsedDisplay = elapsed
        recordingControlDisplayModel.isAnnotateActive = isDrawOverlayVisible
        recordingControlDisplayModel.isPiPActive = isPiPPreviewVisible
        recordingControlDisplayModel.captureMode = recordingCaptureMode
        recordingControlDisplayModel.captureSizeDisplay = recordingSessionLockedCaptureSizeDisplay
            ?? (recordingControlDisplayModel.captureSizeDisplay.isEmpty ? "-- x --" : recordingControlDisplayModel.captureSizeDisplay)
        recordingControlDisplayModel.canRecordToggle = recordingControlMode != .stopping
        recordingControlDisplayModel.canPauseToggle = (recordingControlMode == .recording || recordingControlMode == .paused)
            && recordingControlMode != .stopping
        recordingControlDisplayModel.canClose = recordingControlMode != .stopping
    }

    private func updateRecordingControlSurface() {
        recordingControlController.setMode(recordingControlMode)
        recordingControlController.setDisplayModel(recordingControlDisplayModel)
    }

    private func startRecordingSessionTimer() {
        stopRecordingSessionTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateRecordingControlDisplayModel()
                self.updateRecordingControlSurface()
            }
        }
        recordingSessionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingSessionTimer() {
        recordingSessionTimer?.invalidate()
        recordingSessionTimer = nil
    }

    private func startRecordingControlSizeRefreshTimerIfNeeded() {
        stopRecordingControlSizeRefreshTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.recordingControlController.isVisible else { return }
                guard self.recordingControlMode == .ready || self.recordingControlMode == .paused else { return }
                self.refreshRecordingControlSizeDisplayForCurrentMode()
            }
        }
        recordingControlSizeRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingControlSizeRefreshTimer() {
        recordingControlSizeRefreshTimer?.invalidate()
        recordingControlSizeRefreshTimer = nil
    }

    private func currentRecordingElapsedSeconds() -> TimeInterval {
        recordingSessionElapsedBeforeCurrentSegment
            + (recordingSessionCurrentSegmentStart.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
    }

    private func formatElapsedDisplay(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hh = total / 3600
        let mm = (total % 3600) / 60
        let ss = total % 60
        return String(format: "%02d:%02d:%02d", hh, mm, ss)
    }

    private func formatSizeDisplay(for size: CGSize) -> String {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        return "\(width) x \(height)"
    }

    private func formattedCurrentScreenSizeDisplay() -> String? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let size = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        return formatSizeDisplay(for: size)
    }

    private func normalizedDurationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return durationSeconds
    }

    private func makeSegmentMergedURL() throws -> URL {
        let directory = try DemoFlowOutputDirectoryPolicy.recordingsDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("DemoFlow-segment-merged-\(formatter.string(from: Date())).mp4")
    }

    private func cleanupRecordingSessionSegments(except keepURL: URL) {
        let fileManager = FileManager.default
        for url in recordingSessionSegmentURLs where url.path != keepURL.path {
            try? fileManager.removeItem(at: url)
        }
    }

    private func activeScreenByPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
    }

    private var currentRecordingNativeSize: CGSize? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        return CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
    }

    private func screenDrawWhitelistWindowIDs() -> [CGWindowID] {
        var ids: [CGWindowID] = []
        if screenDrawCanvasController.isVisible, let canvasID = screenDrawCanvasController.currentWindowID {
            ids.append(canvasID)
        }
        if screenDrawToolbarController.isVisible, let toolbarID = screenDrawToolbarController.currentWindowID {
            ids.append(toolbarID)
        }
        return ids
    }

    private func refreshRecordingWindowCaptureIfNeeded() {
        guard recorderState.isRecording else { return }
        pendingDrawCaptureRefreshTask?.cancel()
        pendingDrawCaptureRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshRecordingWindowCapture(retriesRemaining: 6)
        }
    }

    private func refreshRecordingWindowCapture(retriesRemaining: Int) async {
        guard !Task.isCancelled else { return }
        let didIncludeAllRequestedWindows = await syncPiPWindowCaptureState()

        guard retriesRemaining > 0 else { return }
        let drawStillWaiting = isDrawOverlayVisible && screenDrawWhitelistWindowIDs().isEmpty
        let pipStillWaiting = isPiPPreviewVisible && pipController.currentWindowID == nil
        let whitelistStillResolving = !didIncludeAllRequestedWindows
        guard drawStillWaiting || pipStillWaiting || whitelistStillResolving else { return }

        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        await refreshRecordingWindowCapture(retriesRemaining: retriesRemaining - 1)
    }

    private func configureDrawHotkeysIfNeeded() {
        if let drawSystemDefinedMonitor {
            NSEvent.removeMonitor(drawSystemDefinedMonitor)
            self.drawSystemDefinedMonitor = nil
        }

        isDrawGlobalHotkeysEnabled = screenDrawHotkeyService.start()
        drawStatusMessage = isDrawGlobalHotkeysEnabled
            ? L10n.tr("legacy.k_1_5_1_6_c")
            : L10n.tr("legacy.demoflow")
    }

    private func configurePiPHotkeysIfNeeded() {
        isPiPGlobalHotkeysEnabled = pipHotkeyService.start()
    }

    private func configureQuickActionHotkeysIfNeeded() {
        _ = quickActionHotkeyService.start()
    }

    private func handleDrawHotkeyAction(_ action: ScreenDrawHotkeyAction) {
        switch action {
        case let .selectColor(preset):
            screenDrawCanvasController.drawSessionStore.selectedColorPreset = preset
            drawStatusMessage = L10n.f("fmt.draw.color_changed", preset.title)
        case let .selectTool(tool):
            screenDrawCanvasController.drawSessionStore.activeTool = tool
            drawStatusMessage = L10n.f("fmt.draw.tool_changed", tool.title)
        case .toggleOverlay:
            if isDrawOverlayVisible {
                hideScreenDrawOverlay()
                drawStatusMessage = L10n.tr("legacy.key_74")
            } else {
                showScreenDrawOverlay()
                drawStatusMessage = L10n.tr("legacy.key_73")
            }
        case .toggleCanvasPassthrough:
            guard isDrawOverlayVisible else {
                showScreenDrawOverlay()
                setDrawCanvasInteractionEnabled(true)
                drawStatusMessage = L10n.tr("legacy.key_180")
                return
            }
            let nextEnabled = !isDrawCanvasInteractionEnabled
            setDrawCanvasInteractionEnabled(nextEnabled)
            drawStatusMessage = nextEnabled
                ? L10n.tr("legacy.key_180")
                : L10n.tr("legacy.key_179")
        case .undo:
            screenDrawCanvasController.drawSessionStore.undoLastShape()
        }
    }

    private func handlePiPHotkeyAction(_ action: PiPHotkeyAction) {
        switch action {
        case .togglePreview:
            if isPiPPreviewVisible {
                hidePiPPreview()
                pipStatusMessage = L10n.tr("pip.hotkey.hidden")
            } else {
                activatePiPPreview()
                pipStatusMessage = L10n.tr("pip.hotkey.showing")
            }
            refreshRecordingWindowCaptureIfNeeded()
        }
    }

    private func handleQuickActionHotkeyAction(_ action: QuickActionHotkeyAction) {
        switch action {
        case .toggleRecording:
            toggleRecordingFromMenuBar()
        case .togglePiPRecording:
            togglePiPRecordingFromMenuBar()
        }
    }

    private func shouldHandleDrawHotkeyAction(_ action: ScreenDrawHotkeyAction) -> Bool {
        switch action {
        case .toggleOverlay, .toggleCanvasPassthrough:
            return true
        case .selectColor, .selectTool:
            return isDrawOverlayVisible
        case .undo:
            return shouldHandleDrawUndoHotkey()
        }
    }

    private func shouldHandleDrawUndoHotkey() -> Bool {
        guard isDrawOverlayVisible, NSApp.isActive else { return false }

        if screenDrawCanvasController.drawSessionStore.previewShape != nil {
            return true
        }

        if screenDrawToolbarController.isKeyWindow {
            return true
        }

        if isTextInputResponder(NSApp.keyWindow?.firstResponder) {
            return false
        }

        return false
    }

    private func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView {
            return true
        }
        if let textField = responder as? NSTextField {
            return textField.currentEditor() != nil
        }
        if let control = responder as? NSControl {
            return control.currentEditor() != nil
        }
        return false
    }

    private func setDrawCanvasInteractionEnabled(_ enabled: Bool) {
        isDrawCanvasInteractionEnabled = enabled
        screenDrawCanvasController.setCanvasInteractionEnabled(enabled)
    }

    private func handleDrawCanvasScreenRecoveryEvent(_ event: ScreenDrawCanvasWindowController.ScreenRecoveryEvent) {
        guard isDrawOverlayVisible else { return }
        switch event {
        case .switchedToFallbackMainScreen:
            drawStatusMessage = L10n.tr("legacy.key_4")
        case .switchedToFallbackFirstScreen:
            drawStatusMessage = L10n.tr("legacy.key_2")
        case .noAvailableScreen:
            drawStatusMessage = L10n.tr("legacy.key_106")
        case .frameRecomputedAfterScreenChange:
            drawStatusMessage = L10n.tr("legacy.key_156")
        }
    }

    private func handleDrawToolbarScreenRecoveryEvent(_ event: ScreenDrawToolbarWindowController.ScreenRecoveryEvent) {
        guard isDrawOverlayVisible else { return }
        switch event {
        case .switchedToFallbackMainScreen:
            drawStatusMessage = L10n.tr("legacy.key_3")
        case .switchedToFallbackFirstScreen:
            drawStatusMessage = L10n.tr("legacy.key")
        case .noAvailableScreen:
            drawStatusMessage = L10n.tr("legacy.key_106")
        case .frameRecomputedAfterScreenChange:
            drawStatusMessage = L10n.tr("legacy.key_155")
        }
    }

    @discardableResult
    @MainActor
    private func requestScreenRecordingAccessIfNeeded() async -> Bool {
        if #available(macOS 11.0, *) {
            if CGPreflightScreenCaptureAccess() {
                return true
            }

            NSApp.activate(ignoringOtherApps: true)

            if CGRequestScreenCaptureAccess() || CGPreflightScreenCaptureAccess() {
                return true
            }

            if #available(macOS 12.3, *) {
                if await probeScreenCaptureKitAccess() {
                    return true
                }
            }

            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        return true
    }

    private func probeScreenCaptureKitAccess() async -> Bool {
        if #available(macOS 12.3, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                let preferredDisplayID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == preferredDisplayID }) ?? content.displays.first else {
                    return false
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = max(display.width, 2)
                configuration.height = max(display.height, 2)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.queueDepth = 1

                let probe = ScreenCapturePermissionProbe()
                let stream = SCStream(filter: filter, configuration: configuration, delegate: probe)
                try stream.addStreamOutput(
                    probe,
                    type: .screen,
                    sampleHandlerQueue: probe.sampleQueue
                )

                try await stream.startCapture()
                try? await Task.sleep(nanoseconds: 250_000_000)
                try? await stream.stopCapture()
                return true
            } catch {
                let nsError = error as NSError
                print(
                    "[Recording] ScreenCaptureKit permission probe failed: " +
                    "\(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)"
                )
            }
        }
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    private func loadPersistedLanguageOption() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.languageOptionDefaultsKey),
           let option = AppLanguageOption(rawValue: raw) {
            languageOption = option
        } else {
            languageOption = .auto
            defaults.set(languageOption.rawValue, forKey: Self.languageOptionDefaultsKey)
        }
    }

    private func persistLanguageOption() {
        UserDefaults.standard.set(languageOption.rawValue, forKey: Self.languageOptionDefaultsKey)
    }

    private func loadPersistedDrawDismissalAnimationPreferences() {
        let defaults = UserDefaults.standard
        if let rawMode = defaults.string(forKey: Self.drawDismissalAnimationModeDefaultsKey),
           let mode = DrawDismissalAnimationMode(rawValue: rawMode) {
            drawDismissalAnimationMode = mode
        }
        if let rawStyle = defaults.string(forKey: Self.drawDismissalAnimationFixedStyleDefaultsKey),
           let style = DrawDismissalAnimationStyle(rawValue: rawStyle) {
            drawDismissalAnimationFixedStyle = style
        }
        screenDrawCanvasController.drawSessionStore.dismissalAnimationMode = drawDismissalAnimationMode
        screenDrawCanvasController.drawSessionStore.dismissalAnimationFixedStyle = drawDismissalAnimationFixedStyle
    }

    private func loadPersistedDrawAutoCaptureOnCloseEnabled() {
        isDrawAutoCaptureOnCloseEnabled = UserDefaults.standard.bool(
            forKey: Self.drawAutoCaptureOnCloseEnabledDefaultsKey
        )
    }

    private func loadPersistedRecordingQualityConfig() {
        let defaults = UserDefaults.standard
        let preset = RecordingQualityPreset(
            rawValue: defaults.string(forKey: Self.recordingQualityPresetDefaultsKey) ?? ""
        ) ?? RecordingQualityConfig.defaultConfig.preset
        let customResolution = RecordingResolutionPreset(
            rawValue: defaults.string(forKey: Self.recordingQualityCustomResolutionDefaultsKey) ?? ""
        ) ?? RecordingQualityConfig.defaultConfig.customResolution
        let customCodec = RecordingVideoCodec(
            rawValue: defaults.string(forKey: Self.recordingQualityCustomCodecDefaultsKey) ?? ""
        ) ?? RecordingQualityConfig.defaultConfig.customCodec
        let fpsValue = defaults.object(forKey: Self.recordingQualityCustomFPSDefaultsKey) as? Int
            ?? RecordingQualityConfig.defaultConfig.customFPS
        let bitrateValue = defaults.object(forKey: Self.recordingQualityCustomBitrateDefaultsKey) as? Int
            ?? RecordingQualityConfig.defaultConfig.customVideoBitrateMbps

        recordingQualityConfig = RecordingQualityConfig(
            preset: preset,
            customResolution: customResolution,
            customFPS: fpsValue,
            customCodec: customCodec,
            customVideoBitrateMbps: bitrateValue
        ).normalized()
        persistRecordingQualityConfig()
    }

    private func loadPersistedAllRecordingEnabled() {
        isAllRecordingEnabled = UserDefaults.standard.bool(
            forKey: Self.recordingAllCaptureEnabledDefaultsKey
        )
    }

    private func loadPersistedPiPRecordingQualityConfig() {
        let defaults = UserDefaults.standard
        let preset = PiPRecordingQualityPreset(
            rawValue: defaults.string(forKey: Self.pipRecordingQualityPresetDefaultsKey) ?? ""
        ) ?? PiPRecordingQualityConfig.defaultConfig.preset
        let bitrateValue = defaults.object(forKey: Self.pipRecordingQualityCustomBitrateDefaultsKey) as? Int
            ?? PiPRecordingQualityConfig.defaultConfig.customVideoBitrateMbps

        pipRecordingQualityConfig = PiPRecordingQualityConfig(
            preset: preset,
            customVideoBitrateMbps: bitrateValue
        ).normalized()
        persistPiPRecordingQualityConfig()
    }

    private func persistDrawDismissalAnimationMode() {
        UserDefaults.standard.set(
            drawDismissalAnimationMode.rawValue,
            forKey: Self.drawDismissalAnimationModeDefaultsKey
        )
    }

    private func persistDrawDismissalAnimationFixedStyle() {
        UserDefaults.standard.set(
            drawDismissalAnimationFixedStyle.rawValue,
            forKey: Self.drawDismissalAnimationFixedStyleDefaultsKey
        )
    }

    private func persistDrawAutoCaptureOnCloseEnabled() {
        UserDefaults.standard.set(
            isDrawAutoCaptureOnCloseEnabled,
            forKey: Self.drawAutoCaptureOnCloseEnabledDefaultsKey
        )
    }

    private func persistRecordingQualityConfig() {
        let config = recordingQualityConfig.normalized()
        UserDefaults.standard.set(config.preset.rawValue, forKey: Self.recordingQualityPresetDefaultsKey)
        UserDefaults.standard.set(
            config.customResolution.rawValue,
            forKey: Self.recordingQualityCustomResolutionDefaultsKey
        )
        UserDefaults.standard.set(config.customFPS, forKey: Self.recordingQualityCustomFPSDefaultsKey)
        UserDefaults.standard.set(config.customCodec.rawValue, forKey: Self.recordingQualityCustomCodecDefaultsKey)
        UserDefaults.standard.set(
            config.customVideoBitrateMbps,
            forKey: Self.recordingQualityCustomBitrateDefaultsKey
        )
    }

    private func persistAllRecordingEnabled() {
        UserDefaults.standard.set(
            isAllRecordingEnabled,
            forKey: Self.recordingAllCaptureEnabledDefaultsKey
        )
    }

    private func persistPiPRecordingQualityConfig() {
        let config = pipRecordingQualityConfig.normalized()
        UserDefaults.standard.set(config.preset.rawValue, forKey: Self.pipRecordingQualityPresetDefaultsKey)
        UserDefaults.standard.set(
            config.customVideoBitrateMbps,
            forKey: Self.pipRecordingQualityCustomBitrateDefaultsKey
        )
    }

    private func captureScreenDrawCompositeIfNeeded(screen: NSScreen?, canvasImage: NSImage?) {
        guard let canvasImage else {
            drawStatusMessage = L10n.tr("draw.capture.error.canvas_unavailable")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outputURL = try await screenDrawAutoCaptureService.captureAndSave(
                    screen: screen,
                    canvasImage: canvasImage
                )
                drawStatusMessage = L10n.f("fmt.draw.capture_saved", outputURL.lastPathComponent)
            } catch {
                if let captureError = error as? ScreenDrawAutoCaptureError,
                   case .screenCapturePermissionDenied = captureError {
                    drawStatusMessage = captureError.errorDescription ?? L10n.tr("draw.capture.error.permission")
                    return
                }
                drawStatusMessage = L10n.f("fmt.draw.capture_failed", error.localizedDescription)
            }
        }
    }

    private func makeTransparentCanvasImage(for screen: NSScreen?) -> NSImage? {
        guard let screen else { return nil }
        let size = screen.visibleFrame.size
        guard size.width > 1, size.height > 1 else { return nil }
        return NSImage(size: size)
    }

    private func resolveLanguage() {
        let regionID = Locale.autoupdatingCurrent.region?.identifier
        let next = ResolvedAppLanguage.resolve(option: languageOption, regionIdentifier: regionID)
        guard next != resolvedLanguage else { return }
        resolvedLanguage = next
        L10n.setLanguage(next)
    }

    private var privacyPolicyPathSuffix: String {
        switch resolvedLanguage {
        case .zhHans:
            return "zh-hans.html"
        case .en:
            return "en.html"
        }
    }
}

extension Notification.Name {
    static let demoFlowMenuBarCoordinatorReady = Notification.Name("DemoFlowMenuBarCoordinatorReady")
    static let demoFlowRecordingDidFinalizeOutput = Notification.Name("DemoFlowRecordingDidFinalizeOutput")
}

@MainActor
final class MenuBarRecordingController: NSObject, NSMenuDelegate {
    private static let autosaveName = "pjln.top.demoflow.menuBarRecording"
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let recordingToggleItem = NSMenuItem()
    private let pipPreviewToggleItem = NSMenuItem()
    private let pipRecordingToggleItem = NSMenuItem()
    private let screenDrawToggleItem = NSMenuItem()
    private let recordingSettingsItem = NSMenuItem()
    private weak var appCoordinator: AppCoordinator?
    private var isInstalled = false
    private var coordinatorObserver: NSObjectProtocol?

    override init() {
        super.init()
        coordinatorObserver = NotificationCenter.default.addObserver(
            forName: .demoFlowMenuBarCoordinatorReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let coordinator = notification.object as? AppCoordinator else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.configure(appCoordinator: coordinator)
            }
        }
    }

    func configure(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        install()
        refreshMenuItems()
    }

    func install() {
        guard !isInstalled else {
            statusItem?.isVisible = true
            refreshMenuItems()
            return
        }
        isInstalled = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.autosaveName = Self.autosaveName
        statusItem?.isVisible = true
        configureStatusButton()
        configureMenu()
        refreshMenuItems()
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(named: "MenuIcon") {
            let menuIcon = (image.copy() as? NSImage) ?? image
            menuIcon.isTemplate = false
            menuIcon.size = NSSize(width: 18, height: 18)
            button.image = menuIcon
            button.imageScaling = .scaleProportionallyUpOrDown
            button.imagePosition = .imageOnly
        } else {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "DemoFlow")
            button.imagePosition = .imageOnly
        }
        button.title = ""
        button.toolTip = "DemoFlow"
        button.setButtonType(.momentaryPushIn)
        button.appearsDisabled = false
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        recordingToggleItem.target = self
        recordingToggleItem.action = #selector(toggleRecordingFromMenu)
        recordingToggleItem.keyEquivalent = "r"
        recordingToggleItem.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(recordingToggleItem)

        pipPreviewToggleItem.target = self
        pipPreviewToggleItem.action = #selector(togglePiPPreviewFromMenu)
        pipPreviewToggleItem.keyEquivalent = "p"
        pipPreviewToggleItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(pipPreviewToggleItem)

        pipRecordingToggleItem.target = self
        pipRecordingToggleItem.action = #selector(togglePiPRecordingFromMenu)
        pipRecordingToggleItem.keyEquivalent = "p"
        pipRecordingToggleItem.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(pipRecordingToggleItem)

        screenDrawToggleItem.target = self
        screenDrawToggleItem.action = #selector(toggleScreenDrawFromMenu)
        screenDrawToggleItem.keyEquivalent = "s"
        screenDrawToggleItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(screenDrawToggleItem)

        recordingSettingsItem.target = self
        recordingSettingsItem.action = #selector(openRecordingSettingsFromMenu)
        menu.addItem(recordingSettingsItem)

        statusItem?.menu = menu
        statusItem?.autosaveName = Self.autosaveName
        statusItem?.isVisible = true
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        recordingToggleItem.title = L10n.tr("menu.recording_toggle")
        recordingToggleItem.isEnabled = (appCoordinator?.canStartRecording ?? false) || (appCoordinator?.canStopRecording ?? false)

        pipPreviewToggleItem.title = L10n.tr("menu.pip_preview_toggle")
        pipPreviewToggleItem.isEnabled = true

        pipRecordingToggleItem.title = L10n.tr("menu.pip_recording_toggle")
        pipRecordingToggleItem.isEnabled = (appCoordinator?.canStartPiPFilmRecording ?? false)
            || (appCoordinator?.canStopPiPFilmRecording ?? false)
            || (appCoordinator?.isPiPFilmPreparing ?? false)

        screenDrawToggleItem.title = L10n.tr("menu.screen_draw_toggle")
        screenDrawToggleItem.isEnabled = true

        recordingSettingsItem.title = L10n.tr("menu.recording_settings")
        recordingSettingsItem.isEnabled = true
    }

    @objc private func toggleRecordingFromMenu() {
        appCoordinator?.toggleRecordingFromMenuBar()
        refreshMenuItems()
    }

    @objc private func togglePiPPreviewFromMenu() {
        appCoordinator?.togglePiPPreviewFromMenuBar()
        refreshMenuItems()
    }

    @objc private func togglePiPRecordingFromMenu() {
        appCoordinator?.togglePiPRecordingFromMenuBar()
        refreshMenuItems()
    }

    @objc private func toggleScreenDrawFromMenu() {
        appCoordinator?.toggleScreenDrawOverlayFromMenuBar()
        refreshMenuItems()
    }

    @objc private func openRecordingSettingsFromMenu() {
        appCoordinator?.openAppSettingsFromMenuBar()
        refreshMenuItems()
    }

    deinit {
        if let coordinatorObserver {
            NotificationCenter.default.removeObserver(coordinatorObserver)
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}

private final class ScreenCapturePermissionProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    let sampleQueue = DispatchQueue(label: "DemoFlow.screen-capture.permission-probe")

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        _ = stream
        _ = sampleBuffer
        _ = outputType
    }
}
