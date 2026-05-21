//
//  PiPPreviewRuntime.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/1.
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation

final class PiPPreviewRuntime: NSObject, ObservableObject {
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
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewAudioOutput: AVCaptureAudioPreviewOutput?
    private let isPreviewAudioPlaybackEnabled = ProcessInfo.processInfo.environment["PJTOOL_ENABLE_PIP_AUDIO_PREVIEW"] == "1"

    private let sessionQueue = DispatchQueue(label: "demoflow.pip.preview.session")
    private let videoSampleQueue = DispatchQueue(label: "demoflow.pip.preview.video.sample")
    private let audioSampleQueue = DispatchQueue(label: "demoflow.pip.preview.audio.sample")
    private var observers: [NSObjectProtocol] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var recordingSnapshot: SessionSnapshot?

    private let floorLevel: Double = 0.02
    private let decayFactor: Double = 0.84
    private var hasWarnedPreviewAudioPlaybackUnavailable = false
    private var cameraRefreshAttempt = 0
    private var audioRefreshAttempt = 0
    private let maxRefreshAttempt = 2

    var previewSession: AVCaptureSession { session }
    var onProcessingSample: ((CameraProcessingSample) -> Void)?

    init(
        permissionService: CameraPermissionService = .shared,
        deviceCatalog: CameraDeviceCatalog = .shared
    ) {
        self.permissionService = permissionService
        self.deviceCatalog = deviceCatalog
        self.authorizationStatus = permissionService.cameraAuthorizationStatus()
        self.microphoneAuthorizationStatus = permissionService.microphoneAuthorizationStatus()
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
        permissionService.requestCameraAccess { [weak self] granted, status in
            DispatchQueue.main.async {
                guard let self else {
                    onResolved?()
                    return
                }
                self.authorizationStatus = status
                self.infoMessage = granted ? L10n.tr("legacy.key_138") : L10n.tr("legacy.key_140")
                self.refreshSources()
                onResolved?()
            }
        }
    }

    func requestMicrophoneAccess(onResolved: (() -> Void)? = nil) {
        permissionService.requestMicrophoneAccess { [weak self] granted, status in
            DispatchQueue.main.async {
                guard let self else {
                    onResolved?()
                    return
                }
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
        authorizationStatus = permissionService.cameraAuthorizationStatus()
        let snapshot = deviceCatalog.fetchVideoSnapshot(includeOffline: true)
        let mapped = snapshot.devices
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
                self?.refreshSources()
            }
        } else if !mapped.isEmpty {
            cameraRefreshAttempt = 0
        }
    }

    func refreshAudioSources() {
        microphoneAuthorizationStatus = permissionService.microphoneAuthorizationStatus()
        let snapshot = deviceCatalog.fetchAudioSnapshot(includeOffline: true)
        let mapped = snapshot.devices
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
                self?.refreshAudioSources()
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
            rebuildPreviewSession(forceRestartRunningSession: true)
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
            rebuildPreviewSession(forceRestartRunningSession: true)
        }
    }

    func applyPreviewAudioConfig(_ config: PiPAudioPreviewConfig) {
        previewAudioConfig = PiPAudioPreviewConfig(
            isPreviewMuted: config.isPreviewMuted,
            previewVolume: config.clampedVolume
        )
        guard let previewAudioOutput else { return }
        let volume = Float(previewAudioConfig.clampedVolume)
        sessionQueue.async {
            previewAudioOutput.volume = volume
        }
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
        rebuildPreviewSession(forceRestartRunningSession: false)
    }

    func stopPreview() {
        guard isPreviewing, !isRecording else { return }
        isPreviewing = false
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
            throw RecordingError.notAuthorized
        }
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }

        let availableVideoIDs = Set(deviceCatalog.fetchVideoSnapshot(includeOffline: true).devices.map(\.id))
        guard availableVideoIDs.contains(snapshot.videoDeviceID) else {
            refreshSources()
            throw RecordingError.noCamera
        }

        if let audioDeviceID = snapshot.audioDeviceID {
            let availableAudioIDs = Set(deviceCatalog.fetchAudioSnapshot(includeOffline: true).devices.map(\.id))
            if !availableAudioIDs.contains(audioDeviceID) {
                infoMessage = L10n.tr("legacy.pip_21")
            }
        }

        recordingSnapshot = snapshot
        isRecording = true
        isPreviewing = true
        selectSource(withID: snapshot.videoDeviceID)
        if let audioDeviceID = snapshot.audioDeviceID {
            selectAudioSource(withID: audioDeviceID)
        }
        rebuildPreviewSession(forceRestartRunningSession: false)

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
                        self.recordingSnapshot = nil
                        self.infoMessage = L10n.tr("legacy.key_146")
                        self.startContinuation?.resume(throwing: RecordingError.noActiveConnection)
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
            throw RecordingError.notRecording
        }
        guard movieOutput.isRecording else {
            throw RecordingError.notRecording
        }

        let movieOutput = self.movieOutput
        sessionQueue.async {
            movieOutput.stopRecording()
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            stopContinuation = continuation
        }
    }

    private let permissionService: CameraPermissionService
    private let deviceCatalog: CameraDeviceCatalog

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
                if self.isPreviewing || self.isRecording {
                    self.rebuildPreviewSession(forceRestartRunningSession: false)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                guard let device = note.object as? AVCaptureDevice else {
                    self.refreshSources()
                    self.refreshAudioSources()
                    if self.isPreviewing || self.isRecording {
                        self.rebuildPreviewSession(forceRestartRunningSession: false)
                    }
                    return
                }
                if device.uniqueID == self.selectedSourceID {
                    self.infoMessage = L10n.tr("legacy.pip_15")
                } else if device.uniqueID == self.selectedAudioSourceID {
                    self.infoMessage = L10n.tr("legacy.pip_16")
                }
                self.refreshSources()
                self.refreshAudioSources()
                if self.isPreviewing || self.isRecording {
                    self.rebuildPreviewSession(forceRestartRunningSession: false)
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

    private func rebuildPreviewSession(forceRestartRunningSession: Bool) {
        let fixedVideoID = recordingSnapshot?.videoDeviceID
        let fixedAudioID = recordingSnapshot?.audioDeviceID

        guard let sourceID = fixedVideoID ?? effectiveVideoSourceID() else {
            infoMessage = L10n.tr("legacy.key_119")
            return
        }

        let selectedAudioID = fixedAudioID ?? effectiveAudioSourceID()
        let includeAudioInput = microphoneAuthorizationStatus == .authorized && selectedAudioID != nil
        let shouldEnableAudioPreview = isPreviewing && !previewAudioConfig.isPreviewMuted

        let videoSnapshot = deviceCatalog.fetchVideoSnapshot(includeOffline: true)
        let audioSnapshot = deviceCatalog.fetchAudioSnapshot(includeOffline: true)
        guard let videoDevice = videoSnapshot.devices
            .first(where: { $0.id == sourceID })
            .flatMap({ Self.makeDevice(from: $0) }) else {
            refreshSources()
            return
        }
        let audioDevice = audioSnapshot.devices
            .first(where: { $0.id == selectedAudioID })
            .flatMap { Self.makeAudioDevice(from: $0) }

        let session = self.session
        let videoDataOutput = self.videoDataOutput
        let audioDataOutput = self.audioDataOutput
        let movieOutput = self.movieOutput
        let videoSampleQueue = self.videoSampleQueue
        let audioSampleQueue = self.audioSampleQueue
        let previewAudioConfig = self.previewAudioConfig

        sessionQueue.async {
            do {
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

                videoDataOutput.alwaysDiscardsLateVideoFrames = true
                videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoDataOutput.setSampleBufferDelegate(self, queue: videoSampleQueue)
                if session.canAddOutput(videoDataOutput) {
                    session.addOutput(videoDataOutput)
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

                if self.isRecording, session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                }

                session.commitConfiguration()

                if (self.isPreviewing || self.isRecording), !session.isRunning {
                    session.startRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    self.infoMessage = L10n.f("fmt.pip.session_init_failed", error.localizedDescription)
                    self.refreshSources()
                    self.refreshAudioSources()
                }
            }
        }
    }

    private func effectiveVideoSourceID() -> String? {
        let availableIDs = Set(sources.filter(\.isAvailable).map(\.id))
        if let selected = selectedSourceID, availableIDs.contains(selected) {
            return selected
        }
        refreshSources()
        return preferredVideoSource(in: sources.filter(\.isAvailable))?.id
    }

    private func effectiveAudioSourceID() -> String? {
        let availableIDs = Set(audioSources.filter(\.isAvailable).map(\.id))
        if let selected = selectedAudioSourceID, availableIDs.contains(selected) {
            return selected
        }
        refreshAudioSources()
        if let fallback = preferredAudioSource(in: audioSources.filter(\.isAvailable))?.id {
            selectedAudioSourceID = fallback
            return fallback
        }
        return nil
    }

    private func handleVideoSourceFallback(using discovered: [CameraSource]) {
        let available = discovered.filter(\.isAvailable)
        if available.isEmpty {
            selectedSourceID = nil
            return
        }
        if let selectedSourceID, available.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        selectedSourceID = preferredVideoSource(in: available)?.id ?? available.first?.id
    }

    private func handleAudioSourceFallback(using discovered: [AudioInputSource]) {
        let available = discovered.filter(\.isAvailable)
        if available.isEmpty {
            selectedAudioSourceID = nil
            return
        }
        if let selectedAudioSourceID, available.contains(where: { $0.id == selectedAudioSourceID }) {
            return
        }
        selectedAudioSourceID = preferredAudioSource(in: available)?.id ?? available.first?.id
    }

    private func updateVideoAvailabilityMessage(using discovered: [CameraSource]) {
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

    private static func makeDevice(from source: CameraSource) -> AVCaptureDevice? {
        CameraDeviceLookup.videoDevice(uniqueID: source.id)
    }

    private static func makeAudioDevice(from source: AudioInputSource) -> AVCaptureDevice? {
        CameraDeviceLookup.audioDevice(uniqueID: source.id)
    }
}

extension PiPPreviewRuntime: AVCaptureFileOutputRecordingDelegate {
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
            self.recordingSnapshot = nil
            self.startContinuation = nil
            if self.isPreviewing {
                self.rebuildPreviewSession(forceRestartRunningSession: false)
            }

            if let error {
                self.stopContinuation?.resume(throwing: error)
            } else {
                self.stopContinuation?.resume(returning: outputFileURL)
            }
            self.stopContinuation = nil
        }
    }
}

extension PiPPreviewRuntime: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
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
                if !self.previewAudioConfig.isPreviewMuted,
                   !self.isPreviewAudioPlaybackEnabled,
                   !self.hasWarnedPreviewAudioPlaybackUnavailable {
                    self.hasWarnedPreviewAudioPlaybackUnavailable = true
                    self.infoMessage = L10n.tr("legacy.pip_20")
                }
            }
        }
    }
}

private enum CameraDeviceLookup {
    static func videoDevice(uniqueID: String) -> AVCaptureDevice? {
        var all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .continuityCamera,
                .external,
                .deskViewCamera
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
        if let preferred = AVCaptureDevice.default(for: .video),
           !all.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            all.append(preferred)
        }
        return deduped(all).first(where: { $0.uniqueID == uniqueID })
    }

    static func audioDevice(uniqueID: String) -> AVCaptureDevice? {
        var all = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if let preferred = AVCaptureDevice.default(for: .audio),
           !all.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            all.append(preferred)
        }
        return deduped(all).first(where: { $0.uniqueID == uniqueID })
    }

    private static func deduped(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        Array(
            Dictionary(
                devices.map { ($0.uniqueID, $0) },
                uniquingKeysWith: { current, _ in current }
            ).values
        )
    }
}

extension PiPPreviewRuntime {
    struct SessionSnapshot: Equatable {
        let videoDeviceID: String
        let audioDeviceID: String?
    }

    var sessionSnapshot: SessionSnapshot? {
        let selectedVideoID = selectedSourceID
        guard let selectedVideoID else { return nil }
        return SessionSnapshot(
            videoDeviceID: selectedVideoID,
            audioDeviceID: selectedAudioSourceID
        )
    }
}

extension PiPPreviewRuntime {
    enum RecordingError: LocalizedError {
        case notAuthorized
        case alreadyRecording
        case noCamera
        case noActiveConnection
        case notRecording

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return L10n.tr("legacy.key_163")
            case .alreadyRecording:
                return L10n.tr("pip.film.error.already_recording")
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
