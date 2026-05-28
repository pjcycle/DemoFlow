//
//  AudioInputEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

@preconcurrency import AVFoundation
import Combine
import Foundation

final class AudioInputEngine: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: AVAuthorizationStatus
    @Published private(set) var sources: [AudioInputSource] = []
    @Published private(set) var selectedSourceID: String?
    @Published private(set) var level: Double = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var infoMessage: String?

    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "demoflow.audio.session")
    private let sampleQueue = DispatchQueue(label: "demoflow.audio.sample")
    private var observers: [NSObjectProtocol] = []

    private let floorLevel: Double = 0.02
    private let decayFactor: Double = 0.84

    override init() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        super.init()
        configureObservers()
        refreshSources()
    }

    deinit {
        stopMonitoring()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func requestMicrophoneAccess(onResolved: (() -> Void)? = nil) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            DispatchQueue.main.async {
                self.infoMessage = L10n.tr("legacy.nsmicrophoneusagedescription")
                self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                onResolved?()
            }
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
                self.authorizationStatus = status
                self.infoMessage = granted ? nil : L10n.tr("legacy.key_229")
                self.refreshSources()
                if granted {
                    self.startMonitoringIfNeeded()
                }
                onResolved?()
            }
        }
    }

    func refreshSources() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let devices = Self.fetchAudioDevices()
            let mapped = devices.map(AudioInputSource.init(device:))
            DispatchQueue.main.async {
                self.applyDiscoveredSources(mapped)
            }
        }
    }

    func selectSource(withID id: String, userInitiated: Bool = true) {
        guard selectedSourceID != id else { return }
        selectedSourceID = id

        if userInitiated {
            infoMessage = nil
        }

        rebuildCaptureSession(with: id)
    }

    func startMonitoringIfNeeded() {
        guard authorizationStatus == .authorized else { return }
        guard !isMonitoring else { return }
        isMonitoring = true

        if selectedSourceID == nil, let fallback = preferredFallbackSource(in: sources) {
            selectedSourceID = fallback.id
        }

        guard let selectedSourceID else {
            isMonitoring = false
            infoMessage = L10n.tr("legacy.key_159")
            return
        }

        rebuildCaptureSession(with: selectedSourceID)
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.captureSession.beginConfiguration()
            self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }
            self.captureSession.commitConfiguration()
        }

        DispatchQueue.main.async { [weak self] in
            self?.level = 0
        }
    }

    private func configureObservers() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                self.refreshSources()
                if let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) {
                    self.infoMessage = L10n.f("fmt.audio.new_device_detected", device.localizedName)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let device = notification.object as? AVCaptureDevice else {
                    self.refreshSources()
                    return
                }
                if device.uniqueID == self.selectedSourceID {
                    self.infoMessage = L10n.tr("legacy.key_108")
                }
                self.refreshSources()
            }
        )
    }

    private func applyDiscoveredSources(_ discovered: [AudioInputSource]) {
        sources = discovered
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        guard !discovered.isEmpty else {
            selectedSourceID = nil
            infoMessage = L10n.tr("legacy.key_159")
            if isMonitoring {
                stopMonitoring()
            }
            return
        }

        if let selectedSourceID,
           discovered.contains(where: { $0.id == selectedSourceID }) {
            return
        }

        if let fallback = preferredFallbackSource(in: discovered) {
            selectedSourceID = fallback.id
            infoMessage = L10n.f("fmt.audio.auto_switched_to", fallback.name)
            if isMonitoring {
                rebuildCaptureSession(with: fallback.id)
            }
        }
    }

    private func rebuildCaptureSession(with sourceID: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isMonitoring else { return }

            guard let device = Self.fetchAudioDevices().first(where: { $0.uniqueID == sourceID }) else {
                DispatchQueue.main.async {
                    self.infoMessage = L10n.tr("legacy.key_120")
                }
                self.refreshSources()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.captureSession.beginConfiguration()
                self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
                self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }

                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }

                self.audioOutput.setSampleBufferDelegate(self, queue: self.sampleQueue)
                if self.captureSession.canAddOutput(self.audioOutput) {
                    self.captureSession.addOutput(self.audioOutput)
                }

                self.captureSession.commitConfiguration()

                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    self.infoMessage = L10n.f("fmt.audio.monitor_init_failed", error.localizedDescription)
                }
            }
        }
    }

    private func preferredFallbackSource(in sources: [AudioInputSource]) -> AudioInputSource? {
        if let builtIn = sources.first(where: \.isBuiltIn) {
            return builtIn
        }
        if let continuity = sources.first(where: \.isContinuity) {
            return continuity
        }
        return sources.first
    }

    private static func fetchAudioDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices
            .filter { $0.isConnected && !$0.isSuspended }
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
    }
}

extension AudioInputEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let incomingLevel = Self.extractLevel(from: sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let decayed = self.level * self.decayFactor
            let smoothed = max(decayed, incomingLevel)
            self.level = smoothed < self.floorLevel ? 0 : smoothed
        }
    }

    nonisolated private static func extractLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { return 0 }

        let bytesToRead = min(totalLength, 4096)
        var rawBytes = [UInt8](repeating: 0, count: bytesToRead)
        let status = CMBlockBufferCopyDataBytes(
            dataBuffer,
            atOffset: 0,
            dataLength: bytesToRead,
            destination: &rawBytes
        )
        guard status == kCMBlockBufferNoErr else { return 0 }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        let asbd = asbdPointer.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channels = max(Int(asbd.mChannelsPerFrame), 1)

        if isFloat && bitsPerChannel == 32 {
            return levelFromFloat32(rawBytes, channels: channels)
        }
        if bitsPerChannel == 32 {
            return levelFromInt32(rawBytes, channels: channels)
        }
        return levelFromInt16(rawBytes, channels: channels)
    }

    nonisolated private static func levelFromFloat32(_ bytes: [UInt8], channels: Int) -> Double {
        bytes.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Float.self)
            let count = pointer.count
            guard count > 0 else { return 0 }

            let step = max(channels, 1)
            var sum: Double = 0
            var sampleCount = 0
            var index = 0

            while index < count {
                let value = min(abs(Double(pointer[index])), 1)
                sum += value
                sampleCount += 1
                index += step
            }

            guard sampleCount > 0 else { return 0 }
            return min((sum / Double(sampleCount)) * 1.8, 1)
        }
    }

    nonisolated private static func levelFromInt32(_ bytes: [UInt8], channels: Int) -> Double {
        bytes.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int32.self)
            let count = pointer.count
            guard count > 0 else { return 0 }

            let step = max(channels, 1)
            var sum: Double = 0
            var sampleCount = 0
            var index = 0

            while index < count {
                let value = abs(Double(pointer[index])) / Double(Int32.max)
                sum += value
                sampleCount += 1
                index += step
            }

            guard sampleCount > 0 else { return 0 }
            return min((sum / Double(sampleCount)) * 2.2, 1)
        }
    }

    nonisolated private static func levelFromInt16(_ bytes: [UInt8], channels: Int) -> Double {
        bytes.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int16.self)
            let count = pointer.count
            guard count > 0 else { return 0 }

            let step = max(channels, 1)
            var sum: Double = 0
            var sampleCount = 0
            var index = 0

            while index < count {
                let value = abs(Double(pointer[index])) / Double(Int16.max)
                sum += value
                sampleCount += 1
                index += step
            }

            guard sampleCount > 0 else { return 0 }
            return min((sum / Double(sampleCount)) * 2.6, 1)
        }
    }
}
