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
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioDataOutput = AVCaptureAudioDataOutput()
    private var previewAudioOutput: AVCaptureAudioPreviewOutput?
    private let isPreviewAudioPlaybackEnabled = ProcessInfo.processInfo.environment["PJTOOL_ENABLE_PIP_AUDIO_PREVIEW"] == "1"

    private let sessionQueue = DispatchQueue(label: "demoflow.pip.preview.session")
    private let videoSampleQueue = DispatchQueue(label: "demoflow.pip.preview.video.sample")
    private let audioSampleQueue = DispatchQueue(label: "demoflow.pip.preview.audio.sample")
    private var observers: [NSObjectProtocol] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var recordingSnapshot: SessionSnapshot?
    private let recordingWriterLock = NSLock()
    nonisolated(unsafe) private var recordingWriter: PiPRecordingFileWriter?
    private var recordingOutputURL: URL?
    private var recordingFailure: Error?

    private let floorLevel: Double = 0.02
    private let decayFactor: Double = 0.84
    private var hasWarnedPreviewAudioPlaybackUnavailable = false
    private var cameraRefreshAttempt = 0
    private var audioRefreshAttempt = 0
    private let maxRefreshAttempt = 2

    var previewSession: AVCaptureSession { session }
    var onProcessingSample: ((CameraProcessingSample) -> Void)?
    var onRecordingFailure: ((Error) -> Void)?

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
        takeRecordingWriter()?.cancelWriting()
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
        snapshot: SessionSnapshot,
        qualityConfig: PiPRecordingQualityConfig
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

        let writer = try makeRecordingWriter(
            outputURL: url,
            snapshot: snapshot,
            qualityConfig: qualityConfig.normalized()
        )
        recordingSnapshot = snapshot
        recordingFailure = nil
        recordingOutputURL = url
        storeRecordingWriter(writer)
        isRecording = true
        isPreviewing = true
        rebuildPreviewSession(forceRestartRunningSession: false)

        let session = self.session
        let videoDataOutput = self.videoDataOutput
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }

            let hasVideoConnection = videoDataOutput.connection(with: .video)?.isEnabled == true
            guard hasVideoConnection else {
                DispatchQueue.main.async {
                    self.cancelPendingStartContinuation(with: RecordingError.noActiveConnection)
                }
                return
            }
        }

        do {
            try await waitForRecordingStart()
        } catch {
            cleanupFailedRecordingStart(with: error)
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        if let recordingFailure {
            self.recordingFailure = nil
            throw recordingFailure
        }
        guard isRecording else {
            throw RecordingError.notRecording
        }

        let outputURL = recordingOutputURL
        let writer = takeRecordingWriter()
        isRecording = false
        recordingSnapshot = nil
        recordingOutputURL = nil
        if isPreviewing {
            rebuildPreviewSession(forceRestartRunningSession: false)
        }

        guard let writer, let outputURL else {
            throw RecordingError.notRecording
        }

        do {
            try await writer.finishWriting()
            return outputURL
        } catch {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
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

    private func waitForRecordingStart(timeoutNanoseconds: UInt64 = 4_000_000_000) async throws {
        if currentRecordingWriter()?.hasStarted == true {
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                if self.currentRecordingWriter()?.hasStarted == true {
                    return
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.startContinuation = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw RecordingError.startTimedOut
            }

            let result: Void? = try await group.next()
            group.cancelAll()
            if let result {
                return result
            }
        }
    }

    private func resumeRecordingStartContinuation(with result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    private func cancelPendingStartContinuation(with error: Error) {
        resumeRecordingStartContinuation(with: .failure(error))
    }

    private func cleanupFailedRecordingStart(with error: Error) {
        takeRecordingWriter()?.cancelWriting()
        if let recordingOutputURL,
           FileManager.default.fileExists(atPath: recordingOutputURL.path) {
            try? FileManager.default.removeItem(at: recordingOutputURL)
        }
        recordingFailure = error
        recordingOutputURL = nil
        recordingSnapshot = nil
        isRecording = false
        if isPreviewing {
            rebuildPreviewSession(forceRestartRunningSession: false)
        }
    }

    private func handleRecordingWriterEvent(_ event: PiPRecordingFileWriter.Event) {
        switch event {
        case .started:
            resumeRecordingStartContinuation(with: .success(()))
        case let .failed(error):
            let isStarting = startContinuation != nil
            cancelPendingStartContinuation(with: error)
            handleRecordingFailure(error, notifyRuntime: !isStarting)
        }
    }

    private func handleRecordingFailure(_ error: Error, notifyRuntime: Bool) {
        takeRecordingWriter()?.cancelWriting()
        if let recordingOutputURL,
           FileManager.default.fileExists(atPath: recordingOutputURL.path) {
            try? FileManager.default.removeItem(at: recordingOutputURL)
        }
        recordingFailure = error
        recordingOutputURL = nil
        recordingSnapshot = nil
        isRecording = false
        if isPreviewing {
            rebuildPreviewSession(forceRestartRunningSession: false)
        }
        infoMessage = error.localizedDescription
        if notifyRuntime {
            onRecordingFailure?(error)
        }
    }

    private func makeRecordingWriter(
        outputURL: URL,
        snapshot: SessionSnapshot,
        qualityConfig: PiPRecordingQualityConfig
    ) throws -> PiPRecordingFileWriter {
        try PiPRecordingFileWriter(
            outputURL: outputURL,
            captureSize: try resolvedRecordingCaptureSize(for: snapshot.videoDeviceID),
            videoBitrateMbps: qualityConfig.resolvedProfile.videoBitrateMbps,
            audioSettings: makeRecordingAudioSettings(for: snapshot.audioDeviceID)
        )
    }

    private func resolvedRecordingCaptureSize(for videoDeviceID: String) throws -> CGSize {
        let snapshot = deviceCatalog.fetchVideoSnapshot(includeOffline: true)
        guard let device = snapshot.devices
            .first(where: { $0.id == videoDeviceID })
            .flatMap(Self.makeDevice(from:)) else {
            throw RecordingError.noCamera
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return normalizedRecordingSize(
            CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        )
    }

    private func normalizedRecordingSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded(.down)))
        let height = max(2, Int(size.height.rounded(.down)))
        let evenWidth = width.isMultiple(of: 2) ? width : width - 1
        let evenHeight = height.isMultiple(of: 2) ? height : height - 1
        return CGSize(width: max(2, evenWidth), height: max(2, evenHeight))
    }

    private func makeRecordingAudioSettings(for audioDeviceID: String?) -> [String: Any]? {
        guard let audioDeviceID, !audioDeviceID.isEmpty else {
            return nil
        }

        let fallbackSampleRate = 48_000.0
        let fallbackChannels = 1
        let device = CameraDeviceLookup.audioDevice(uniqueID: audioDeviceID)
        let formatDescription = device?.activeFormat.formatDescription
        let asbd = formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd?.mSampleRate ?? fallbackSampleRate,
            AVNumberOfChannelsKey: max(Int(asbd?.mChannelsPerFrame ?? UInt32(fallbackChannels)), 1),
            AVEncoderBitRateKey: 128_000
        ]
    }

    nonisolated private func currentRecordingWriter() -> PiPRecordingFileWriter? {
        recordingWriterLock.lock()
        defer { recordingWriterLock.unlock() }
        return recordingWriter
    }

    nonisolated private func storeRecordingWriter(_ writer: PiPRecordingFileWriter) {
        recordingWriterLock.lock()
        recordingWriter = writer
        recordingWriterLock.unlock()
    }

    nonisolated private func takeRecordingWriter() -> PiPRecordingFileWriter? {
        recordingWriterLock.lock()
        defer { recordingWriterLock.unlock() }
        let writer = recordingWriter
        recordingWriter = nil
        return writer
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

    nonisolated private static func makeDevice(from source: CameraSource) -> AVCaptureDevice? {
        CameraDeviceLookup.videoDevice(uniqueID: source.id)
    }

    nonisolated private static func makeAudioDevice(from source: AudioInputSource) -> AVCaptureDevice? {
        CameraDeviceLookup.audioDevice(uniqueID: source.id)
    }
}

private struct PiPSendableSampleBuffer: @unchecked Sendable {
    nonisolated(unsafe) let value: CMSampleBuffer
}

extension PiPPreviewRuntime: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        let incomingLevel = CameraAudioLevelExtractor.extract(from: sampleBuffer)
        let sendableSample = PiPSendableSampleBuffer(value: sampleBuffer)
        if output === videoDataOutput {
            currentRecordingWriter()?.appendVideoSample(sendableSample.value) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleRecordingWriterEvent(event)
                }
            }
        } else if output === audioDataOutput {
            currentRecordingWriter()?.appendAudioSample(sendableSample.value) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleRecordingWriterEvent(event)
                }
            }
        }
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

private final class PiPRecordingFileWriter {
    enum Event {
        case started
        case failed(Error)
    }

    enum WriterError: LocalizedError {
        case outputCreationFailed(String)
        case addVideoInputFailed
        case addAudioInputFailed
        case startWritingFailed
        case videoAppendFailed
        case audioAppendFailed
        case noVideoFrames
        case finishWritingFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case let .outputCreationFailed(message):
                return message
            case .addVideoInputFailed:
                return L10n.tr("recording.quality.error.video_input")
            case .addAudioInputFailed:
                return L10n.tr("recording.quality.error.audio_input")
            case .startWritingFailed:
                return L10n.tr("recording.quality.error.start_writer")
            case .videoAppendFailed:
                return L10n.tr("recording.quality.error.video_append")
            case .audioAppendFailed:
                return L10n.tr("recording.quality.error.audio_append")
            case .noVideoFrames:
                return L10n.tr("recording.quality.error.no_video_frames")
            case .finishWritingFailed:
                return L10n.tr("recording.quality.error.finish_writer")
            case .cancelled:
                return L10n.tr("recording.quality.error.writer_cancelled")
            }
        }
    }

    private let queue = DispatchQueue(label: "DemoFlow.pip-recording.file-writer")
    nonisolated(unsafe) private let assetWriter: AVAssetWriter
    nonisolated(unsafe) private let videoInput: AVAssetWriterInput
    nonisolated(unsafe) private let audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var sessionStartTime: CMTime?
    nonisolated(unsafe) private var didEmitStartedEvent = false
    nonisolated(unsafe) private var didEmitFailureEvent = false
    nonisolated(unsafe) private var isFinishing = false

    var hasStarted: Bool {
        queue.sync {
            sessionStartTime != nil
        }
    }

    init(
        outputURL: URL,
        captureSize: CGSize,
        videoBitrateMbps: Int,
        audioSettings: [String: Any]?
    ) throws {
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw WriterError.outputCreationFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(captureSize.width),
            AVVideoHeightKey: Int(captureSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrateMbps * 1_000_000
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(videoInput) else {
            throw WriterError.addVideoInputFailed
        }
        assetWriter.add(videoInput)

        if let audioSettings {
            let nextAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            nextAudioInput.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(nextAudioInput) else {
                throw WriterError.addAudioInputFailed
            }
            assetWriter.add(nextAudioInput)
            audioInput = nextAudioInput
        } else {
            audioInput = nil
        }
    }

    nonisolated func appendVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        eventHandler: @escaping (Event) -> Void
    ) {
        let boxedSample = PiPSendableSampleBuffer(value: sampleBuffer)
        queue.async {
            guard !self.isFinishing else { return }
            if self.assetWriter.status == .failed {
                self.emitFailure(self.assetWriter.error ?? WriterError.finishWritingFailed, eventHandler: eventHandler)
                return
            }
            guard CMSampleBufferGetImageBuffer(boxedSample.value) != nil else { return }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(boxedSample.value)
            if self.sessionStartTime == nil {
                guard self.assetWriter.startWriting() else {
                    self.emitFailure(self.assetWriter.error ?? WriterError.startWritingFailed, eventHandler: eventHandler)
                    return
                }
                self.assetWriter.startSession(atSourceTime: presentationTime)
                self.sessionStartTime = presentationTime
            }
            guard self.videoInput.isReadyForMoreMediaData else { return }
            guard self.videoInput.append(boxedSample.value) else {
                self.emitFailure(self.assetWriter.error ?? WriterError.videoAppendFailed, eventHandler: eventHandler)
                return
            }
            if !self.didEmitStartedEvent {
                self.didEmitStartedEvent = true
                eventHandler(.started)
            }
        }
    }

    nonisolated func appendAudioSample(
        _ sampleBuffer: CMSampleBuffer,
        eventHandler: @escaping (Event) -> Void
    ) {
        let boxedSample = PiPSendableSampleBuffer(value: sampleBuffer)
        queue.async {
            guard !self.isFinishing else { return }
            guard let audioInput = self.audioInput, let sessionStartTime = self.sessionStartTime else { return }
            if self.assetWriter.status == .failed {
                self.emitFailure(self.assetWriter.error ?? WriterError.finishWritingFailed, eventHandler: eventHandler)
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(boxedSample.value)
            guard CMTimeCompare(presentationTime, sessionStartTime) >= 0 else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            guard audioInput.append(boxedSample.value) else {
                self.emitFailure(self.assetWriter.error ?? WriterError.audioAppendFailed, eventHandler: eventHandler)
                return
            }
        }
    }

    nonisolated func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.isFinishing = true
                self.videoInput.markAsFinished()
                self.audioInput?.markAsFinished()

                switch self.assetWriter.status {
                case .unknown:
                    self.assetWriter.cancelWriting()
                    continuation.resume(throwing: WriterError.noVideoFrames)
                case .writing:
                    self.assetWriter.finishWriting {
                        switch self.assetWriter.status {
                        case .completed:
                            continuation.resume(returning: ())
                        case .cancelled:
                            continuation.resume(throwing: WriterError.cancelled)
                        case .failed:
                            continuation.resume(throwing: self.assetWriter.error ?? WriterError.finishWritingFailed)
                        default:
                            continuation.resume(throwing: WriterError.finishWritingFailed)
                        }
                    }
                case .completed:
                    continuation.resume(returning: ())
                case .cancelled:
                    continuation.resume(throwing: WriterError.cancelled)
                case .failed:
                    continuation.resume(throwing: self.assetWriter.error ?? WriterError.finishWritingFailed)
                @unknown default:
                    continuation.resume(throwing: WriterError.finishWritingFailed)
                }
            }
        }
    }

    nonisolated func cancelWriting() {
        queue.async {
            self.isFinishing = true
            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            self.assetWriter.cancelWriting()
        }
    }

    nonisolated private func emitFailure(_ error: Error, eventHandler: @escaping (Event) -> Void) {
        guard !didEmitFailureEvent else { return }
        didEmitFailureEvent = true
        eventHandler(.failed(error))
    }
}

private enum CameraDeviceLookup {
    nonisolated static func videoDevice(uniqueID: String) -> AVCaptureDevice? {
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

    nonisolated static func audioDevice(uniqueID: String) -> AVCaptureDevice? {
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

    nonisolated private static func deduped(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
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
        case startTimedOut
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
            case .startTimedOut:
                return L10n.tr("pip.film.error.start_timeout")
            case .notRecording:
                return L10n.tr("legacy.key_135")
            }
        }
    }
}
