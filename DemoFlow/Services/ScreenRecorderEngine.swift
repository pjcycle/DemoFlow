//
//  ScreenRecorderEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreGraphics
@preconcurrency import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenRecorderEngine: NSObject, ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var statusMessage: String = L10n.tr("legacy.key_115")
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var lastArtifact: RecordingArtifact?

    private let cameraEngine: CameraEngine
    private let compositionEngine = CompositionExportEngine()
    private let pipProcessingEngine = PiPFrameProcessingEngine()
    private let recordingSampleQueue = DispatchQueue(label: "DemoFlow.screen-recorder.sample-writer")

    private var stream: SCStream?
    private var currentRequest: RecordingRequest?
    private var activeCaptureDisplayID: CGDirectDisplayID?
    private var includesPiPWindowInScreenCapture = false

    private var screenRawURL: URL?
    private var cameraRawURL: URL?
    private var cameraFramingSidecarURL: URL?
    private var currentFaceKeyframes: [FaceFramingKeyframe] = []

    private var recordingStartContinuation: CheckedContinuation<Void, Error>?
    private var hasWrittenFirstScreenFrame = false
    private var stopScreenCaptureTimedOut = false
    nonisolated(unsafe) private var screenFileWriter: ScreenCaptureFileWriter?

    enum RecordingStopReason {
        case pause
        case finalize
    }

    init(
        cameraEngine: CameraEngine
    ) {
        self.cameraEngine = cameraEngine
        super.init()
    }

    func startRecording(
        request: RecordingRequest,
        preferredScreen: NSScreen?
    ) async {
        _ = preferredScreen
        guard !state.isBusy else { return }
        guard !state.isRecording else { return }
        if cameraEngine.isRecording {
            _ = try? await cameraEngine.stopRecording()
        }
        state = .preparing
        statusMessage = L10n.tr("legacy.key_21")
        currentRequest = request
        lastArtifact = nil

        do {
            let outputContext = try makeOutputContext()
            screenRawURL = outputContext.screenRawURL
            cameraRawURL = outputContext.cameraRawURL
            cameraFramingSidecarURL = outputContext.cameraFramingSidecarURL
            currentFaceKeyframes = []

            pipProcessingEngine.configure(
                processingConfig: request.pipProcessingConfig,
                aspectRatio: request.pipAspectRatio
            )
            pipProcessingEngine.reset()
            cameraEngine.applyPreviewAudioConfig(request.pipAudioPreviewConfig)
            cameraEngine.setProcessingEnabled(true)

            var cameraTrackEnabled = false
            if let cameraID = request.cameraDeviceID, let cameraRawURL {
                cameraEngine.selectSource(withID: cameraID)
                let cameraAudioID = request.cameraAudioDeviceID ?? request.microphoneDeviceID
                if let cameraAudioID {
                    cameraEngine.selectAudioSource(withID: cameraAudioID)
                }
                let snapshot = CameraEngine.SessionSnapshot(
                    videoDeviceID: cameraID,
                    audioDeviceID: cameraAudioID
                )

                cameraEngine.onProcessingSample = { [weak self] sample in
                    guard let self else { return }
                    guard let result = self.pipProcessingEngine.processFrame(from: sample.sampleBuffer) else { return }
                    if let keyframe = result.keyframe {
                        self.currentFaceKeyframes.append(keyframe)
                    }
                }

                do {
                    try await cameraEngine.startRecording(to: cameraRawURL, snapshot: snapshot)
                    cameraTrackEnabled = true
                } catch {
                    cameraEngine.onProcessingSample = nil
                    currentFaceKeyframes = []
                    statusMessage = L10n.tr("legacy.key_136")
                }
            }

            let streamBundle = try await buildScreenStream(
                screenRawURL: outputContext.screenRawURL,
                request: request
            )
            stream = streamBundle.stream
            screenFileWriter = streamBundle.fileWriter
            activeCaptureDisplayID = streamBundle.displayID
            includesPiPWindowInScreenCapture = streamBundle.includesPiPWindowInScreenCapture
            hasWrittenFirstScreenFrame = false

            statusMessage = L10n.tr("legacy.key_190")
            try await streamBundle.stream.startCapture()
            try await waitForRecordingStart()
            state = .recording
            let recordingStatus = cameraTrackEnabled ? L10n.tr("legacy.key_114") : L10n.tr("legacy.key_113")
            let withMic = request.microphoneDeviceID != nil
            let inputStatus = withMic ? L10n.tr("legacy.key_231") : L10n.tr("legacy.key_230")
            let pipCaptureStatus = includesPiPWindowInScreenCapture ? L10n.tr("legacy.pip_11") : L10n.tr("legacy.pip_10")
            statusMessage = streamBundle.warnsAppWindowExclusion
                ? L10n.f("fmt.recording.status_with_warning", recordingStatus, inputStatus, pipCaptureStatus)
                : L10n.f("fmt.recording.status", recordingStatus, inputStatus, pipCaptureStatus)
        } catch {
            cancelPendingContinuations(with: error)
            if cameraEngine.isRecording {
                _ = try? await cameraEngine.stopRecording()
            }
            screenFileWriter?.cancelWriting()
            cameraEngine.stopPreview()
            cleanupTemporaryState()
            state = .failed(presentableErrorMessage(error))
            statusMessage = L10n.f("fmt.recording.start_failed", presentableErrorMessage(error))
        }
    }

    func stopRecording(reason: RecordingStopReason = .finalize) async {
        guard !state.isBusy else { return }
        guard stream != nil else { return }
        state = .stopping
        statusMessage = L10n.tr("legacy.key_14")

        let layout = currentRequest?.pipLayout ?? .default
        cameraEngine.onProcessingSample = nil
        let activeWriter = screenFileWriter

        do {
            if let stream {
                try await stopScreenCapture(stream: stream)
            }
            self.stream = nil

            if let activeWriter {
                try await activeWriter.finishWriting()
            }

            var capturedCameraURL: URL?
            if cameraEngine.isRecording {
                let rawCameraURL = try await cameraEngine.stopRecording()
                if currentRequest?.cameraDeviceID != nil {
                    capturedCameraURL = rawCameraURL
                } else {
                    capturedCameraURL = nil
                    try? FileManager.default.removeItem(at: rawCameraURL)
                }
            }

            var sidecarURL: URL?
            if let capturedCameraURL {
                let keyframesFromAsset = await pipProcessingEngine.processAssetForKeyframes(cameraURL: capturedCameraURL)
                let finalKeyframes = PiPFramingKeyframeNormalizer.normalized(
                    keyframesFromAsset.isEmpty ? currentFaceKeyframes : keyframesFromAsset
                )
                if !finalKeyframes.isEmpty, let candidate = cameraFramingSidecarURL {
                    try writeSidecar(keyframes: finalKeyframes, to: candidate)
                    sidecarURL = candidate
                }
                currentFaceKeyframes = finalKeyframes
            } else {
                currentFaceKeyframes = []
            }

            let screenURL = try ensureURL(screenRawURL, name: L10n.tr("legacy.key_79"))
            try validateRecordedScreenOutput(at: screenURL)
            let finalURL: URL
            if reason == .pause {
                // Pause path keeps an intermediate segment only; session-level final output is created on finalize.
                let segmentURL = try makePausedSegmentURL()
                finalURL = try await compositionEngine.mergeScreenAndCamera(
                    screenURL: screenURL,
                    cameraURL: capturedCameraURL,
                    pipLayout: layout,
                    faceFramingKeyframes: currentFaceKeyframes,
                    outputURL: segmentURL
                )
            } else {
                let mergedURL = try makeMergedURL()
                finalURL = try await compositionEngine.mergeScreenAndCamera(
                    screenURL: screenURL,
                    cameraURL: capturedCameraURL,
                    pipLayout: layout,
                    faceFramingKeyframes: currentFaceKeyframes,
                    outputURL: mergedURL
                )
            }

            let artifact = RecordingArtifact(
                screenURL: screenURL,
                cameraURL: capturedCameraURL,
                mergedURL: finalURL,
                cameraFramingSidecarURL: sidecarURL
            )
            lastArtifact = artifact
            if reason == .finalize {
                lastOutputURL = finalURL
            }
            statusMessage = stopScreenCaptureTimedOut
                ? L10n.tr("legacy.key_110")
                : L10n.tr("legacy.key_109")
            state = .idle
            cleanupTemporaryState()
        } catch {
            if cameraEngine.isRecording {
                _ = try? await cameraEngine.stopRecording()
            }
            screenFileWriter?.cancelWriting()
            cameraEngine.stopPreview()
            state = .failed(presentableErrorMessage(error))
            statusMessage = L10n.f("fmt.recording.stop_failed", presentableErrorMessage(error))
            cleanupTemporaryState()
        }
    }

    func applyPostProcessedOutputURL(_ outputURL: URL) {
        lastOutputURL = outputURL
        if let artifact = lastArtifact {
            lastArtifact = RecordingArtifact(
                screenURL: artifact.screenURL,
                cameraURL: artifact.cameraURL,
                mergedURL: outputURL,
                cameraFramingSidecarURL: artifact.cameraFramingSidecarURL
            )
        }
    }

    @discardableResult
    func updatePiPWindowCapture(windowID: CGWindowID?, extraWindowIDs: [CGWindowID] = []) async -> WindowCaptureResolution {
        let requestedWindowIDs = Set(([windowID].compactMap { $0 }) + extraWindowIDs)
        guard state.isRecording else {
            return WindowCaptureResolution(
                requestedPiPWindowID: windowID,
                requestedWindowIDs: requestedWindowIDs,
                matchedWindowIDs: []
            )
        }
        guard let stream else {
            return WindowCaptureResolution(
                requestedPiPWindowID: windowID,
                requestedWindowIDs: requestedWindowIDs,
                matchedWindowIDs: []
            )
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = resolvedDisplay(from: content, preferredID: activeCaptureDisplayID) else {
                return WindowCaptureResolution(
                    requestedPiPWindowID: windowID,
                    requestedWindowIDs: requestedWindowIDs,
                    matchedWindowIDs: []
                )
            }
            let filterContext = makeDisplayFilterContext(
                from: content,
                display: display,
                pipWindowID: windowID,
                extraIncludedWindowIDs: extraWindowIDs,
                includeAppWindowsInCapture: currentRequest?.includeAppWindowsInCapture ?? false
            )
            try await stream.updateContentFilter(filterContext.filter)
            includesPiPWindowInScreenCapture = filterContext.includesPiPWindowInScreenCapture
            return filterContext.windowCaptureResolution
        } catch {
            statusMessage = L10n.f("fmt.recording.update_pip_capture_failed", presentableErrorMessage(error))
            return WindowCaptureResolution(
                requestedPiPWindowID: windowID,
                requestedWindowIDs: requestedWindowIDs,
                matchedWindowIDs: []
            )
        }
    }

    private func stopScreenCapture(stream: SCStream) async throws {
        stopScreenCaptureTimedOut = false
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await stream.stopCapture()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 6_000_000_000)
                    throw RecorderError.stopTimedOut
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch RecorderError.stopTimedOut {
            stopScreenCaptureTimedOut = true
        }
    }

    private func buildScreenStream(
        screenRawURL: URL,
        request: RecordingRequest
    ) async throws -> (
        stream: SCStream,
        fileWriter: ScreenCaptureFileWriter,
        warnsAppWindowExclusion: Bool,
        displayID: CGDirectDisplayID,
        includesPiPWindowInScreenCapture: Bool
    ) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let preferredDisplayID: CGDirectDisplayID = {
            if request.captureMode == .region, let selection = request.regionSelection {
                return selection.displayID
            }
            return CGMainDisplayID()
        }()

        guard let display = resolvedDisplay(from: content, preferredID: preferredDisplayID) else {
            throw RecorderError.noDisplay
        }

        if request.captureMode == .region, display.displayID != preferredDisplayID {
            throw RecorderError.regionDisplayUnavailable
        }
        let filterContext = makeDisplayFilterContext(
            from: content,
            display: display,
            pipWindowID: request.pipWindowID,
            extraIncludedWindowIDs: request.screenDrawWindowIDs,
            includeAppWindowsInCapture: request.includeAppWindowsInCapture
        )

        let configuration = SCStreamConfiguration()
        let scale = max(CGFloat(filterContext.filter.pointPixelScale), 1)

        let captureRectInDisplayPoints: CGRect?
        if request.captureMode == .region {
            guard let selection = request.regionSelection else {
                throw RecorderError.invalidRegion
            }
            let clampedRect = clampedRegionRect(
                selection.rectInDisplayPoints,
                displaySizeInPoints: CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            )
            guard clampedRect.width >= 2, clampedRect.height >= 2 else {
                throw RecorderError.invalidRegion
            }
            configuration.sourceRect = clampedRect
            captureRectInDisplayPoints = clampedRect
        } else {
            captureRectInDisplayPoints = nil
        }

        let nativeCaptureSize: CGSize = {
            if let captureRectInDisplayPoints {
                return CGSize(
                    width: captureRectInDisplayPoints.width * scale,
                    height: captureRectInDisplayPoints.height * scale
                )
            }
            return CGSize(
                width: CGFloat(display.width) * scale,
                height: CGFloat(display.height) * scale
            )
        }()
        let profile = request.recordingQuality.resolvedProfile
        let captureSize = resolvedCaptureSize(nativeCaptureSize: nativeCaptureSize, profile: profile)
        configuration.width = max(2, Int(captureSize.width))
        configuration.height = max(2, Int(captureSize.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(profile.fps))
        configuration.queueDepth = 5
        configuration.capturesAudio = false
        configuration.captureMicrophone = request.microphoneDeviceID?.isEmpty == false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if let micID = request.microphoneDeviceID, !micID.isEmpty {
            configuration.microphoneCaptureDeviceID = micID
        }

        let fileWriter = try ScreenCaptureFileWriter(
            outputURL: screenRawURL,
            captureSize: captureSize,
            codec: profile.codec,
            fps: profile.fps,
            videoBitrateMbps: profile.videoBitrateMbps,
            audioSettings: configuration.captureMicrophone
                ? makeMicrophoneAudioSettings(for: request.microphoneDeviceID)
                : nil
        )

        let stream = SCStream(filter: filterContext.filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: recordingSampleQueue)
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: recordingSampleQueue)
        }

        return (
            stream: stream,
            fileWriter: fileWriter,
            warnsAppWindowExclusion: filterContext.warnsAppWindowExclusion,
            displayID: display.displayID,
            includesPiPWindowInScreenCapture: filterContext.includesPiPWindowInScreenCapture
        )
    }

    private func clampedRegionRect(
        _ rect: CGRect,
        displaySizeInPoints: CGSize
    ) -> CGRect {
        var next = rect.standardized
        let minWidth: CGFloat = 2
        let minHeight: CGFloat = 2

        next.origin.x = max(0, min(next.origin.x, max(0, displaySizeInPoints.width - minWidth)))
        next.origin.y = max(0, min(next.origin.y, max(0, displaySizeInPoints.height - minHeight)))
        next.size.width = max(minWidth, min(next.width, displaySizeInPoints.width - next.origin.x))
        next.size.height = max(minHeight, min(next.height, displaySizeInPoints.height - next.origin.y))
        return next.integral
    }

    private func resolvedDisplay(
        from content: SCShareableContent,
        preferredID: CGDirectDisplayID?
    ) -> SCDisplay? {
        if let preferredID,
           let matched = content.displays.first(where: { $0.displayID == preferredID }) {
            return matched
        }
        return content.displays.first
    }

    private func makeDisplayFilterContext(
        from content: SCShareableContent,
        display: SCDisplay,
        pipWindowID: CGWindowID?,
        extraIncludedWindowIDs: [CGWindowID],
        includeAppWindowsInCapture: Bool
    ) -> DisplayFilterContext {
        let mainBundleID = Bundle.main.bundleIdentifier
        let excludedApplicationBundleIDs = Set(
            (
                includeAppWindowsInCapture
                    ? ["com.apple.dock", mainBundleID]
                    : ["com.apple.dock", mainBundleID]
            ).compactMap { $0 }
        )
        let excludedApplications = content.applications.filter { application in
            excludedApplicationBundleIDs.contains(application.bundleIdentifier)
        }
        let requestedWindowIDs = Set(([pipWindowID].compactMap { $0 }) + extraIncludedWindowIDs)
        var filterAllowedWindowIDs = requestedWindowIDs
        if includeAppWindowsInCapture, let mainBundleID {
            let appOwnedWindowIDs = content.windows.compactMap { window -> CGWindowID? in
                guard window.owningApplication?.bundleIdentifier == mainBundleID else {
                    return nil
                }
                return window.windowID
            }
            filterAllowedWindowIDs.formUnion(appOwnedWindowIDs)
        }

        let includedWindows = content.windows.filter { window in
            filterAllowedWindowIDs.contains(window.windowID)
        }
        let includedWindowIDs = Set(includedWindows.map(\.windowID))
        let matchedRequestedWindowIDs = requestedWindowIDs.intersection(includedWindowIDs)
        if !requestedWindowIDs.isEmpty,
           requestedWindowIDs != matchedRequestedWindowIDs {
            let missingWindowIDs = requestedWindowIDs.subtracting(matchedRequestedWindowIDs).sorted()
            print("[RecordingWhitelist] unresolved windowIDs=\(missingWindowIDs)")
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: includedWindows
        )
        let warnsAppWindowExclusion = !excludedApplications.contains { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return DisplayFilterContext(
            filter: filter,
            warnsAppWindowExclusion: warnsAppWindowExclusion,
            windowCaptureResolution: WindowCaptureResolution(
                requestedPiPWindowID: pipWindowID,
                requestedWindowIDs: requestedWindowIDs,
                matchedWindowIDs: matchedRequestedWindowIDs
            )
        )
    }

    private func waitForRecordingStart(timeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        if hasWrittenFirstScreenFrame {
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                if self.hasWrittenFirstScreenFrame {
                    return
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.recordingStartContinuation = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw RecorderError.startTimedOut
            }

            let result: Void? = try await group.next()
            group.cancelAll()
            if let result {
                return result
            }
        }
    }

    private func makeOutputContext() throws -> OutputContext {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let screenRawURL = folder.appendingPathComponent("screen-\(timestamp).mp4")
        let cameraRawURL = folder.appendingPathComponent("camera-\(timestamp).mov")
        let cameraFramingSidecarURL = folder.appendingPathComponent("camera-framing-\(timestamp).json")
        return OutputContext(
            screenRawURL: screenRawURL,
            cameraRawURL: cameraRawURL,
            cameraFramingSidecarURL: cameraFramingSidecarURL
        )
    }

    private func makeMergedURL() throws -> URL {
        let folder = try DemoFlowOutputDirectoryPolicy.recordingsDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return folder.appendingPathComponent("DemoFlow-\(formatter.string(from: Date())).mp4")
    }

    private func makePausedSegmentURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("recording-segments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return folder.appendingPathComponent("segment-\(formatter.string(from: Date())).mp4")
    }

    private func ensureURL(_ url: URL?, name: String) throws -> URL {
        guard let url else {
            throw RecorderError.missingIntermediate(name)
        }
        return url
    }

    private func validateRecordedScreenOutput(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecorderError.missingIntermediate(L10n.tr("legacy.key_79"))
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if (values.fileSize ?? 0) <= 0 {
            throw RecorderError.emptyIntermediate(L10n.tr("legacy.key_79"))
        }
    }

    private func cleanupTemporaryState() {
        hasWrittenFirstScreenFrame = false
        stopScreenCaptureTimedOut = false
        recordingStartContinuation = nil
        stream = nil
        activeCaptureDisplayID = nil
        includesPiPWindowInScreenCapture = false
        screenRawURL = nil
        cameraRawURL = nil
        cameraFramingSidecarURL = nil
        currentFaceKeyframes = []
        cameraEngine.onProcessingSample = nil
        currentRequest = nil
        screenFileWriter = nil
    }

    private func writeSidecar(keyframes: [FaceFramingKeyframe], to url: URL) throws {
        struct Sidecar: Codable {
            let generatedAt: Date
            let keyframes: [FaceFramingKeyframe]
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let sidecar = Sidecar(generatedAt: Date(), keyframes: keyframes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url)
    }

    private func resumeRecordingStartContinuation(with result: Result<Void, Error>) {
        guard let continuation = recordingStartContinuation else { return }
        recordingStartContinuation = nil
        switch result {
        case .success:
            continuation.resume(returning: ())
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func cancelPendingContinuations(with error: Error) {
        resumeRecordingStartContinuation(with: .failure(error))
    }

    private func presentableErrorMessage(_ error: Error) -> String {
        if let recorderError = error as? RecorderError {
            return recorderError.displayMessage
        }
        if let writerError = error as? ScreenCaptureFileWriter.WriterError {
            return writerError.localizedDescription
        }
        return error.localizedDescription
    }

    private func resolvedCaptureSize(
        nativeCaptureSize: CGSize,
        profile: RecordingQualityProfile
    ) -> CGSize {
        guard let boundingSize = profile.resolution.boundingSize(for: nativeCaptureSize) else {
            return evenCaptureSize(nativeCaptureSize)
        }

        let scale = min(
            1,
            min(boundingSize.width / nativeCaptureSize.width, boundingSize.height / nativeCaptureSize.height)
        )
        let scaledSize = CGSize(
            width: nativeCaptureSize.width * scale,
            height: nativeCaptureSize.height * scale
        )
        return evenCaptureSize(scaledSize)
    }

    private func evenCaptureSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded(.down)))
        let height = max(2, Int(size.height.rounded(.down)))
        let evenWidth = width.isMultiple(of: 2) ? width : width - 1
        let evenHeight = height.isMultiple(of: 2) ? height : height - 1
        return CGSize(width: max(2, evenWidth), height: max(2, evenHeight))
    }

    private func makeMicrophoneAudioSettings(for microphoneDeviceID: String?) -> [String: Any] {
        let fallbackSampleRate = 48_000.0
        let fallbackChannels = 1

        guard let microphoneDeviceID, !microphoneDeviceID.isEmpty else {
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fallbackSampleRate,
                AVNumberOfChannelsKey: fallbackChannels,
                AVEncoderBitRateKey: 128_000
            ]
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let device = discoverySession.devices.first(where: { $0.uniqueID == microphoneDeviceID })
        let formatDescription = device?.activeFormat.formatDescription
        let asbd = formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd?.mSampleRate ?? fallbackSampleRate,
            AVNumberOfChannelsKey: max(Int(asbd?.mChannelsPerFrame ?? UInt32(fallbackChannels)), 1),
            AVEncoderBitRateKey: 128_000
        ]
    }

    private func handleWriterEvent(_ event: ScreenCaptureFileWriter.Event) {
        switch event {
        case .started:
            guard !hasWrittenFirstScreenFrame else { return }
            hasWrittenFirstScreenFrame = true
            resumeRecordingStartContinuation(with: .success(()))
        case let .failed(error):
            if state == .preparing {
                cancelPendingContinuations(with: error)
                return
            }
            guard state.isRecording || state.isBusy else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelPendingContinuations(with: error)
                if let stream = self.stream {
                    try? await stream.stopCapture()
                }
                if self.cameraEngine.isRecording {
                    _ = try? await self.cameraEngine.stopRecording()
                }
                self.screenFileWriter?.cancelWriting()
                self.cameraEngine.stopPreview()
                self.cleanupTemporaryState()
                self.state = .failed(self.presentableErrorMessage(error))
                self.statusMessage = L10n.f("fmt.recording.unexpected_stop", self.presentableErrorMessage(error))
            }
        }
    }
}

extension ScreenRecorderEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cancelPendingContinuations(with: error)
            self.state = .failed(self.presentableErrorMessage(error))
            self.statusMessage = L10n.f("fmt.recording.unexpected_stop", self.presentableErrorMessage(error))
        }
    }
}

extension ScreenRecorderEngine: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        guard outputType == .screen || outputType == .microphone else {
            return
        }
        guard let screenFileWriter else { return }

        screenFileWriter.append(sampleBuffer: sampleBuffer, outputType: outputType) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleWriterEvent(event)
            }
        }
    }
}

extension ScreenRecorderEngine {
    private struct OutputContext {
        let screenRawURL: URL
        let cameraRawURL: URL
        let cameraFramingSidecarURL: URL
    }

    private struct DisplayFilterContext {
        let filter: SCContentFilter
        let warnsAppWindowExclusion: Bool
        let windowCaptureResolution: WindowCaptureResolution

        var includesPiPWindowInScreenCapture: Bool {
            windowCaptureResolution.includesRequestedPiPWindow
        }
    }

    struct WindowCaptureResolution {
        let requestedPiPWindowID: CGWindowID?
        let requestedWindowIDs: Set<CGWindowID>
        let matchedWindowIDs: Set<CGWindowID>

        var didIncludeAllRequestedWindows: Bool {
            requestedWindowIDs == matchedWindowIDs
        }

        var includesRequestedPiPWindow: Bool {
            guard let pipWindowID = requestedPiPWindowID else { return false }
            return matchedWindowIDs.contains(pipWindowID)
        }
    }

    enum RecorderError: Error {
        case noDisplay
        case regionDisplayUnavailable
        case invalidRegion
        case missingIntermediate(String)
        case emptyIntermediate(String)
        case startTimedOut
        case stopTimedOut

        @MainActor
        var displayMessage: String {
            switch self {
            case .noDisplay:
                return L10n.tr("legacy.key_173")
            case .regionDisplayUnavailable:
                return L10n.tr("recording.region.error.display_unavailable")
            case .invalidRegion:
                return L10n.tr("recording.region.error.invalid_region")
            case let .missingIntermediate(name):
                return L10n.f("fmt.recording.missing_intermediate", name)
            case let .emptyIntermediate(name):
                return L10n.f("fmt.recording.missing_intermediate", name)
            case .startTimedOut:
                return L10n.tr("legacy.key_192")
            case .stopTimedOut:
                return L10n.tr("legacy.key_16")
            }
        }
    }
}

private final class ScreenCaptureFileWriter: @unchecked Sendable {
    enum Event {
        case started
        case failed(Error)
    }

    private struct SendableSampleBuffer: @unchecked Sendable {
        let value: CMSampleBuffer
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

    private let queue = DispatchQueue(label: "DemoFlow.screen-recorder.file-writer")
    nonisolated(unsafe) private let assetWriter: AVAssetWriter
    nonisolated(unsafe) private let videoInput: AVAssetWriterInput
    nonisolated(unsafe) private let audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var sessionStartTime: CMTime?
    nonisolated(unsafe) private var didEmitStartedEvent = false
    nonisolated(unsafe) private var didEmitFailureEvent = false
    nonisolated(unsafe) private var isFinishing = false

    init(
        outputURL: URL,
        captureSize: CGSize,
        codec: RecordingVideoCodec,
        fps: Int,
        videoBitrateMbps: Int,
        audioSettings: [String: Any]?
    ) throws {
        let videoCodecType: AVVideoCodecType = codec == .hevc ? .hevc : .h264
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw WriterError.outputCreationFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodecType,
            AVVideoWidthKey: Int(captureSize.width),
            AVVideoHeightKey: Int(captureSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrateMbps * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: fps
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

    nonisolated func append(
        sampleBuffer: CMSampleBuffer,
        outputType: SCStreamOutputType,
        eventHandler: @escaping (Event) -> Void
    ) {
        let boxedSampleBuffer = SendableSampleBuffer(value: sampleBuffer)
        queue.async {
            guard !self.isFinishing else { return }
            if self.assetWriter.status == .failed {
                self.emitFailure(self.assetWriter.error ?? WriterError.finishWritingFailed, eventHandler: eventHandler)
                return
            }
            switch outputType {
            case .screen:
                self.appendVideoSample(boxedSampleBuffer.value, eventHandler: eventHandler)
            case .microphone:
                self.appendAudioSample(boxedSampleBuffer.value, eventHandler: eventHandler)
            default:
                break
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

    nonisolated private func appendVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        eventHandler: @escaping (Event) -> Void
    ) {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if sessionStartTime == nil {
            guard assetWriter.startWriting() else {
                emitFailure(assetWriter.error ?? WriterError.startWritingFailed, eventHandler: eventHandler)
                return
            }
            assetWriter.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        guard videoInput.append(sampleBuffer) else {
            emitFailure(assetWriter.error ?? WriterError.videoAppendFailed, eventHandler: eventHandler)
            return
        }

        if !didEmitStartedEvent {
            didEmitStartedEvent = true
            eventHandler(.started)
        }
    }

    nonisolated private func appendAudioSample(
        _ sampleBuffer: CMSampleBuffer,
        eventHandler: @escaping (Event) -> Void
    ) {
        guard let audioInput, let sessionStartTime else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(presentationTime, sessionStartTime) >= 0 else { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        guard audioInput.append(sampleBuffer) else {
            emitFailure(assetWriter.error ?? WriterError.audioAppendFailed, eventHandler: eventHandler)
            return
        }
    }

    nonisolated private func emitFailure(_ error: Error, eventHandler: @escaping (Event) -> Void) {
        guard !didEmitFailureEvent else { return }
        didEmitFailureEvent = true
        eventHandler(.failed(error))
    }
}
