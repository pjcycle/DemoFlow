//
//  CameraEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation

final class CameraEngine: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: AVAuthorizationStatus
    @Published private(set) var microphoneAuthorizationStatus: AVAuthorizationStatus
    @Published private(set) var sources: [CameraSource] = []
    @Published private(set) var audioSources: [AudioInputSource] = []
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var selectedAudioSourceID: String?
    @Published private(set) var previewAudioConfig: PiPAudioPreviewConfig = .default
    @Published private(set) var previewAudioLevel: Double = 0
    @Published private(set) var isPreviewing = false
    @Published private(set) var isRecording = false
    @Published private(set) var infoMessage: String?
    @Published private(set) var lastVideoRefreshAt: Date?
    @Published private(set) var lastAudioRefreshAt: Date?
    @Published private(set) var lastVideoEnumeratedCount = 0
    @Published private(set) var lastVideoAvailableCount = 0
    @Published private(set) var lastAudioEnumeratedCount = 0
    @Published private(set) var lastAudioAvailableCount = 0
    @Published private(set) var lastVideoDiscoveryCount = 0
    @Published private(set) var lastAudioDiscoveryCount = 0
    @Published private(set) var lastVideoUsedLegacyFallback = false
    @Published private(set) var lastAudioUsedLegacyFallback = false
    @Published private(set) var lastVideoIncludedSystemDefault = false

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private var previewAudioOutput: AVCaptureAudioPreviewOutput?
    private let isPreviewAudioPlaybackEnabled = ProcessInfo.processInfo.environment["PJTOOL_ENABLE_PIP_AUDIO_PREVIEW"] == "1"

    private let sessionQueue = DispatchQueue(label: "demoflow.camera.session")
    private let videoSampleQueue = DispatchQueue(label: "demoflow.camera.video.sample")
    private let audioSampleQueue = DispatchQueue(label: "demoflow.camera.audio.sample")
    private var observers: [NSObjectProtocol] = []

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var recordingURL: URL?

    private var sessionSnapshot: SessionSnapshot?
    private var processingEnabled = true
    private var floorLevel: Double = 0.02
    private var decayFactor: Double = 0.84
    private var didWarnVideoFallback = false
    private var didWarnAudioFallback = false
    private var cameraRefreshAttempt = 0
    private var audioRefreshAttempt = 0
    private let maxRefreshAttempt = 2
    private var hasWarnedPreviewAudioPlaybackUnavailable = false

    var previewSession: AVCaptureSession { session }
    var activeSessionSnapshot: SessionSnapshot? { sessionSnapshot }

    var onProcessingSample: ((CameraProcessingSample) -> Void)?

    override init() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        super.init()
        configureObservers()
        refreshSources()
        refreshAudioSources()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        sessionQueue.sync {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func requestCameraAccess(onResolved: (() -> Void)? = nil) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            infoMessage = L10n.tr("legacy.nscamerausagedescription")
            authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            onResolved?()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else {
                DispatchQueue.main.async {
                    onResolved?()
                }
                return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            DispatchQueue.main.async {
                self.authorizationStatus = status
                self.infoMessage = granted ? L10n.tr("legacy.key_138") : L10n.tr("legacy.key_140")
                self.refreshSources()
                onResolved?()
            }
        }
    }

    func requestMicrophoneAccess(onResolved: (() -> Void)? = nil) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            infoMessage = L10n.tr("legacy.nsmicrophoneusagedescription")
            onResolved?()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else {
                DispatchQueue.main.async {
                    onResolved?()
                }
                return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            DispatchQueue.main.async {
                self.microphoneAuthorizationStatus = status
                if granted {
                    self.refreshAudioSources()
                } else {
                    self.infoMessage = L10n.tr("legacy.pip_28")
                }
                onResolved?()
            }
        }
    }

    func refreshSources() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let snapshot = Self.fetchVideoDiscovery(includeOffline: true)
        let mapped = snapshot.devices.map(CameraSource.init(device:))
        sources = mapped
        lastVideoRefreshAt = Date()
        lastVideoEnumeratedCount = mapped.count
        lastVideoAvailableCount = mapped.filter(\.isAvailable).count
        lastVideoDiscoveryCount = snapshot.discoveryCount
        lastVideoUsedLegacyFallback = snapshot.usedLegacyFallback
        lastVideoIncludedSystemDefault = snapshot.includedSystemDefault
        handleVideoSourceFallback(using: mapped)
        updateVideoAvailabilityMessage(using: mapped)

        if authorizationStatus == .authorized,
           mapped.isEmpty,
           cameraRefreshAttempt < maxRefreshAttempt {
            cameraRefreshAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.refreshSources()
            }
        } else if !mapped.isEmpty {
            cameraRefreshAttempt = 0
        }
    }

    func refreshAudioSources() {
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let snapshot = Self.fetchAudioDiscovery(includeOffline: true)
        let mapped = snapshot.devices.map(AudioInputSource.init(device:))
        audioSources = mapped
        lastAudioRefreshAt = Date()
        lastAudioEnumeratedCount = mapped.count
        lastAudioAvailableCount = mapped.filter(\.isAvailable).count
        lastAudioDiscoveryCount = snapshot.discoveryCount
        lastAudioUsedLegacyFallback = snapshot.usedLegacyFallback
        handleAudioSourceFallback(using: mapped)

        if microphoneAuthorizationStatus == .authorized,
           mapped.isEmpty,
           audioRefreshAttempt < maxRefreshAttempt {
            audioRefreshAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.refreshAudioSources()
            }
        } else if !mapped.isEmpty {
            audioRefreshAttempt = 0
        }
    }

    func selectSource(withID id: String) {
        guard selectedSourceID != id else { return }
        selectedSourceID = id
        if let source = sources.first(where: { $0.id == id }) {
            infoMessage = L10n.f("fmt.pip.current_camera", source.name)
        } else {
            infoMessage = nil
        }
        if isPreviewing || isRecording {
            rebuildSession(
                includeMovieOutput: isRecording,
                forceRestartRunningSession: isPreviewing && !isRecording
            )
        }
    }

    func selectAudioSource(withID id: String) {
        guard selectedAudioSourceID != id else { return }
        selectedAudioSourceID = id
        if let source = audioSources.first(where: { $0.id == id }) {
            infoMessage = L10n.f("fmt.pip.current_microphone", source.name)
        } else {
            infoMessage = nil
        }
        if isPreviewing || isRecording {
            rebuildSession(
                includeMovieOutput: isRecording,
                forceRestartRunningSession: isPreviewing && !isRecording
            )
        }
    }

    func applyPreviewAudioConfig(_ config: PiPAudioPreviewConfig) {
        var nextConfig = PiPAudioPreviewConfig(
            isPreviewMuted: config.isPreviewMuted,
            previewVolume: config.clampedVolume
        )
        if !isPreviewAudioPlaybackEnabled, !nextConfig.isPreviewMuted {
            nextConfig.isPreviewMuted = true
            if !hasWarnedPreviewAudioPlaybackUnavailable {
                infoMessage = L10n.tr("legacy.pip_18")
                hasWarnedPreviewAudioPlaybackUnavailable = true
            }
        }
        previewAudioConfig = nextConfig
        let volume = Float(previewAudioConfig.clampedVolume)
        let previewOutput = previewAudioOutput
        sessionQueue.async {
            previewOutput?.volume = volume
        }
    }

    func setProcessingEnabled(_ enabled: Bool) {
        processingEnabled = enabled
    }

    func startPreviewIfNeeded() {
        guard authorizationStatus == .authorized else { return }
        guard !isPreviewing else { return }

        if selectedSourceID == nil {
            refreshSources()
        }
        if selectedAudioSourceID == nil {
            refreshAudioSources()
        }

        isPreviewing = true
        rebuildSession(includeMovieOutput: false)
        let session = self.session
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stopPreview() {
        guard isPreviewing, !isRecording else { return }
        isPreviewing = false
        sessionSnapshot = nil
        previewAudioLevel = 0
        onProcessingSample = nil
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func startRecording(
        to url: URL,
        snapshot: SessionSnapshot
    ) async throws {
        guard authorizationStatus == .authorized else {
            throw CameraError.notAuthorized
        }
        guard !isRecording else { return }

        let availableVideoIDs = Set(Self.fetchVideoDevices().map(\.uniqueID))
        guard availableVideoIDs.contains(snapshot.videoDeviceID) else {
            refreshSources()
            throw CameraError.noCamera
        }

        if let audioID = snapshot.audioDeviceID {
            let availableAudioIDs = Set(Self.fetchAudioDevices().map(\.uniqueID))
            if !availableAudioIDs.contains(audioID) {
                infoMessage = L10n.tr("legacy.pip_21")
            }
        }

        sessionSnapshot = snapshot
        recordingURL = url
        isRecording = true
        isPreviewing = true
        didWarnVideoFallback = false
        didWarnAudioFallback = false

        rebuildSession(includeMovieOutput: true)

        let session = self.session
        let movieOutput = self.movieOutput
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            sessionQueue.async {
                if !session.isRunning {
                    session.startRunning()
                }

                let hasVideoConnection = movieOutput.connection(with: .video)?.isEnabled == true
                guard hasVideoConnection else {
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.sessionSnapshot = nil
                        self.infoMessage = L10n.tr("legacy.key_146")
                        self.startContinuation?.resume(throwing: CameraError.noActiveConnection)
                        self.startContinuation = nil
                    }
                    return
                }

                movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func stopRecording() async throws -> URL {
        guard isRecording else {
            throw CameraError.notRecording
        }
        guard movieOutput.isRecording else {
            throw CameraError.notRecording
        }

        let movieOutput = self.movieOutput
        sessionQueue.async {
            movieOutput.stopRecording()
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            stopContinuation = continuation
        }
    }

    private func configureObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                if let device = note.object as? AVCaptureDevice {
                    if device.hasMediaType(.video) {
                        self.infoMessage = L10n.f("fmt.pip.new_camera_detected", device.localizedName)
                    } else if device.hasMediaType(.audio) {
                        self.infoMessage = L10n.f("fmt.pip.new_audio_device_detected", device.localizedName)
                    }
                }
                self.refreshSources()
                self.refreshAudioSources()
            }
        )

        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                defer {
                    self.refreshSources()
                    self.refreshAudioSources()
                    if self.isPreviewing || self.isRecording {
                        self.rebuildSession(includeMovieOutput: self.isRecording)
                    }
                }
                guard let device = note.object as? AVCaptureDevice else { return }

                if device.uniqueID == self.selectedSourceID {
                    self.infoMessage = L10n.tr("legacy.pip_15")
                } else if device.uniqueID == self.selectedAudioSourceID {
                    self.infoMessage = L10n.tr("legacy.pip_16")
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.refreshSources()
                self.refreshAudioSources()
            }
        )
    }

    private func handleVideoSourceFallback(using discovered: [CameraSource]) {
        let available = discovered.filter(\.isAvailable)
        if available.isEmpty {
            selectedSourceID = nil
            return
        }

        if let selectedSourceID,
           available.contains(where: { $0.id == selectedSourceID }) {
            return
        }

        if let preferred = preferredVideoSource(in: available) {
            selectedSourceID = preferred.id
            return
        }

        selectedSourceID = available.first?.id
    }

    private func updateVideoAvailabilityMessage(using discovered: [CameraSource]) {
        guard !isRecording else { return }

        switch authorizationStatus {
        case .notDetermined:
            infoMessage = L10n.tr("legacy.key_64")
        case .denied:
            infoMessage = L10n.tr("legacy.demoflow_5")
        case .restricted:
            infoMessage = L10n.tr("legacy.key_137")
        case .authorized:
            if discovered.isEmpty {
                infoMessage = L10n.tr("legacy.continuity_camera")
            } else if discovered.allSatisfy({ !$0.isAvailable }) {
                infoMessage = L10n.tr("legacy.key_92")
            } else if let selectedSourceID,
                      let selected = discovered.first(where: { $0.id == selectedSourceID }),
                      selected.isAvailable {
                infoMessage = nil
            }
        @unknown default:
            break
        }
    }

    private func handleAudioSourceFallback(using discovered: [AudioInputSource]) {
        let available = discovered.filter(\.isAvailable)
        if available.isEmpty {
            selectedAudioSourceID = nil
            return
        }

        if let selectedAudioSourceID,
           available.contains(where: { $0.id == selectedAudioSourceID }) {
            return
        }

        if let preferred = preferredAudioSource(in: available) {
            selectedAudioSourceID = preferred.id
            return
        }

        selectedAudioSourceID = available.first?.id
    }

    private func rebuildSession(
        includeMovieOutput: Bool,
        forceRestartRunningSession: Bool = false
    ) {
        guard let sourceID = effectiveVideoSourceID() else {
            if includeMovieOutput {
                infoMessage = L10n.tr("legacy.pip_24")
            }
            return
        }

        let selectedAudioID = effectiveAudioSourceID()
        let previewAudioConfig = self.previewAudioConfig
        let shouldEnableAudioPreview = isPreviewAudioPlaybackEnabled && isPreviewing && !previewAudioConfig.isPreviewMuted
        let shouldRunProcessing = processingEnabled && isPreviewing
        let includeAudioInput = microphoneAuthorizationStatus == .authorized && selectedAudioID != nil

        let videoDevice = Self.fetchVideoDevices().first(where: { $0.uniqueID == sourceID })
        guard let videoDevice else {
            handleVideoUnavailable(includeMovieOutput: includeMovieOutput)
            return
        }

        let audioDevice = Self.fetchAudioDevices().first(where: { $0.uniqueID == selectedAudioID })
        if includeAudioInput && audioDevice == nil {
            if !didWarnAudioFallback {
                infoMessage = L10n.tr("legacy.pip_22")
                didWarnAudioFallback = true
            }
        }

        let session = self.session
        let videoDataOutput = self.videoDataOutput
        let audioDataOutput = self.audioDataOutput
        let movieOutput = self.movieOutput
        let videoSampleQueue = self.videoSampleQueue
        let audioSampleQueue = self.audioSampleQueue

        sessionQueue.async {
            do {
                let shouldKeepRunning = self.isPreviewing || self.isRecording
                let shouldRestartRunningSession = forceRestartRunningSession && session.isRunning
                if shouldRestartRunningSession {
                    session.stopRunning()
                }

                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                let audioInput = try audioDevice.map(AVCaptureDeviceInput.init(device:))

                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }

                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                }
                if let audioInput, session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }

                videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
                audioDataOutput.setSampleBufferDelegate(nil, queue: nil)

                if shouldRunProcessing {
                    videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    videoDataOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    videoDataOutput.setSampleBufferDelegate(self, queue: videoSampleQueue)
                    if session.canAddOutput(videoDataOutput) {
                        session.addOutput(videoDataOutput)
                    }
                }

                if includeAudioInput {
                    audioDataOutput.setSampleBufferDelegate(self, queue: audioSampleQueue)
                    if session.canAddOutput(audioDataOutput) {
                        session.addOutput(audioDataOutput)
                    }
                    if shouldEnableAudioPreview {
                        if self.previewAudioOutput == nil {
                            self.previewAudioOutput = AVCaptureAudioPreviewOutput()
                        }
                        if let previewAudioOutput = self.previewAudioOutput {
                            previewAudioOutput.volume = Float(previewAudioConfig.clampedVolume)
                            if session.canAddOutput(previewAudioOutput) {
                                session.addOutput(previewAudioOutput)
                            }
                        }
                    }
                }

                if includeMovieOutput, session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                }

                session.commitConfiguration()

                if shouldKeepRunning && !session.isRunning {
                    session.startRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    self.infoMessage = L10n.f("fmt.pip.session_init_failed", error.localizedDescription)
                    if self.isRecording {
                        self.sessionSnapshot = nil
                        self.refreshSources()
                        self.refreshAudioSources()
                    }
                }
            }
        }
    }

    private func activeVideoSourceID() -> String? {
        if let snapshot = sessionSnapshot, isRecording {
            return snapshot.videoDeviceID
        }
        return selectedSourceID
    }

    private func activeAudioSourceID() -> String? {
        if let snapshot = sessionSnapshot, isRecording {
            return snapshot.audioDeviceID
        }
        return selectedAudioSourceID
    }

    private func effectiveVideoSourceID() -> String? {
        let availableIDs = Set(Self.fetchVideoDevices().map(\.uniqueID))
        if let active = activeVideoSourceID(), availableIDs.contains(active) {
            return active
        }
        if let selected = selectedSourceID, availableIDs.contains(selected) {
            return selected
        }
        refreshSources()
        return preferredVideoSource(in: sources.filter(\.isAvailable))?.id
    }

    private func effectiveAudioSourceID() -> String? {
        let availableIDs = Set(Self.fetchAudioDevices().map(\.uniqueID))
        if let active = activeAudioSourceID(), availableIDs.contains(active) {
            return active
        }
        if let selected = selectedAudioSourceID, availableIDs.contains(selected) {
            return selected
        }
        refreshAudioSources()
        let fallback = preferredAudioSource(in: audioSources.filter(\.isAvailable))?.id
        if let fallback {
            selectedAudioSourceID = fallback
        }
        return fallback
    }

    private func handleVideoUnavailable(includeMovieOutput: Bool) {
        refreshSources()
        if let fallbackID = preferredVideoSource(in: sources.filter(\.isAvailable))?.id {
            selectedSourceID = fallbackID
        }
        if !didWarnVideoFallback {
            infoMessage = includeMovieOutput
                ? L10n.tr("legacy.pip_14")
                : L10n.tr("legacy.key_119")
            didWarnVideoFallback = true
        }
    }

    private func preferredVideoSource(in sources: [CameraSource]) -> CameraSource? {
        if let builtIn = sources.first(where: \.isBuiltIn) {
            return builtIn
        }
        if let continuity = sources.first(where: \.isContinuity) {
            return continuity
        }
        return sources.first
    }

    private func preferredAudioSource(in sources: [AudioInputSource]) -> AudioInputSource? {
        if let builtIn = sources.first(where: \.isBuiltIn) {
            return builtIn
        }
        if let continuity = sources.first(where: \.isContinuity) {
            return continuity
        }
        return sources.first
    }

    private static func fetchVideoDevices(includeOffline: Bool = false) -> [AVCaptureDevice] {
        fetchVideoDiscovery(includeOffline: includeOffline).devices
    }

    private static func fetchVideoDiscovery(includeOffline: Bool) -> DiscoverySnapshot {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .continuityCamera,
                .external,
                .deskViewCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        let discoveryDevices = discoverySession.devices
        var devices = discoveryDevices
        var usedLegacyFallback = false
        var includedSystemDefault = false

        if devices.isEmpty {
            usedLegacyFallback = true
        }
        if let preferred = AVCaptureDevice.default(for: .video),
           !devices.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            devices.append(preferred)
            includedSystemDefault = true
        }

        let deduplicated = Dictionary(devices.map { ($0.uniqueID, $0) }, uniquingKeysWith: { current, _ in current })
            .values
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
        let filtered = includeOffline ? deduplicated : deduplicated.filter { $0.isConnected && !$0.isSuspended }
        return DiscoverySnapshot(
            devices: filtered,
            discoveryCount: discoveryDevices.count,
            usedLegacyFallback: usedLegacyFallback,
            includedSystemDefault: includedSystemDefault
        )
    }

    private static func fetchAudioDevices(includeOffline: Bool = false) -> [AVCaptureDevice] {
        fetchAudioDiscovery(includeOffline: includeOffline).devices
    }

    private static func fetchAudioDiscovery(includeOffline: Bool) -> DiscoverySnapshot {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let discoveryDevices = discoverySession.devices
        var devices = discoveryDevices
        var usedLegacyFallback = false

        if devices.isEmpty {
            usedLegacyFallback = true
        }

        if let preferred = AVCaptureDevice.default(for: .audio),
           !devices.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            devices.append(preferred)
        }

        let deduplicated = Dictionary(devices.map { ($0.uniqueID, $0) }, uniquingKeysWith: { current, _ in current })
            .values
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
        let filtered = includeOffline ? deduplicated : deduplicated.filter { $0.isConnected && !$0.isSuspended }
        return DiscoverySnapshot(
            devices: filtered,
            discoveryCount: discoveryDevices.count,
            usedLegacyFallback: usedLegacyFallback,
            includedSystemDefault: false
        )
    }

    private struct DiscoverySnapshot {
        let devices: [AVCaptureDevice]
        let discoveryCount: Int
        let usedLegacyFallback: Bool
        let includedSystemDefault: Bool
    }
}

extension CameraEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor [weak self] in
            self?.startContinuation?.resume(returning: ())
            self?.startContinuation = nil
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.sessionSnapshot = nil

            if let error {
                self.stopContinuation?.resume(throwing: error)
                self.stopContinuation = nil
                self.startContinuation = nil
                return
            }

            self.stopContinuation?.resume(returning: outputFileURL)
            self.stopContinuation = nil
            self.startContinuation = nil
            self.recordingURL = nil
        }
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private struct SendableSampleBuffer: @unchecked Sendable {
        let value: CMSampleBuffer
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let incomingLevel = CameraAudioLevelExtractor.extract(from: sampleBuffer)
        let sendableSample = SendableSampleBuffer(value: sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if output === self.videoDataOutput {
                self.onProcessingSample?(
                    CameraProcessingSample(
                        sampleBuffer: sendableSample.value,
                        source: .livePreview
                    )
                )
                return
            }

            if output === self.audioDataOutput {
                let decayed = self.previewAudioLevel * self.decayFactor
                let smoothed = max(decayed, incomingLevel)
                self.previewAudioLevel = smoothed < self.floorLevel ? 0 : smoothed
            }
        }
    }

}

extension CameraEngine {
    struct SessionSnapshot: Equatable {
        let videoDeviceID: String
        let audioDeviceID: String?
    }

    enum CameraError: LocalizedError {
        case notAuthorized
        case noCamera
        case noActiveConnection
        case notRecording

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return L10n.tr("legacy.key_163")
            case .noCamera:
                return L10n.tr("legacy.key_162")
            case .noActiveConnection:
                return L10n.tr("legacy.key_145")
            case .notRecording:
                return L10n.tr("legacy.key_135")
            }
        }
    }
}
