import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class VideoDubbingViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var audioURL: URL?
    @Published private(set) var exportURL: URL?
    @Published private(set) var state: SubDubSessionState = .idle
    @Published private(set) var statusMessage: String = L10n.tr("subdub.video.status.idle")
    @Published private(set) var isPlayerReady = false
    @Published private(set) var isMetering = false
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var waveformSamples: [Double] = []
    @Published private(set) var isPreviewPlaying = false

    let player = AVPlayer()

    private let workspace = SubDubWorkspaceService()
    private let exportService = SubDubExportService()
    private var recorder: AVAudioRecorder?
    private var sessionDirectory: URL?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var meteringTimer: Timer?
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?
    private let waveformSampleCount = 512

    override init() {
        super.init()
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackPosition = max(0, time.seconds)
                self.isPreviewPlaying = self.state == .finished && self.player.timeControlStatus == .playing
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as AnyObject? === self.player.currentItem else { return }
            Task { @MainActor [weak self] in
                self?.isPreviewPlaying = false
                self?.finishRecordingIfNeeded()
            }
        }
    }

    deinit {
        meteringTimer?.invalidate()
        if let timeObserverToken { player.removeTimeObserver(timeObserverToken) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var hasSource: Bool { sourceURL != nil }
    var hasAudio: Bool { audioURL != nil && state == .finished }
    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    var playbackPositionText: String {
        "\(formatTime(playbackPosition)) / \(formatTime(sourceDuration))"
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        self.subscriptionViewModel = subscriptionViewModel
        self.onRequireSubscription = onRequireSubscription
    }

    func importVideoByPanel() {
        guard let url = workspace.pickVideoURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importVideo(from: url)
    }

    func importVideo(from url: URL) {
        Task { await loadVideo(from: url) }
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let typeIdentifier = workspace.videoTypes.map(\.identifier).first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) ?? UTType.fileURL.identifier
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                self?.importVideo(from: url)
            }
        }
    }

    func prepareDubbing() {
        guard sourceURL != nil else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        recorder?.stop()
        recorder = nil
        removeTemporaryAudio()
        player.pause()
        player.isMuted = false
        isPreviewPlaying = false
        player.seek(to: .zero)
        stopMetering()
        state = .ready
        statusMessage = L10n.tr("subdub.video.status.ready")
        Task { await restoreSourcePreview() }
    }

    func startRecording() {
        guard sourceURL != nil else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        if state == .paused {
            continueRecording()
            return
        }
        guard state == .ready || state == .failed else { return }
        requestMicrophoneAndStart()
    }

    func pauseRecording() {
        guard state == .recording else { return }
        recorder?.pause()
        player.pause()
        isPreviewPlaying = false
        stopMetering()
        state = .paused
        statusMessage = L10n.tr("subdub.video.status.paused")
    }

    func continueRecording() {
        guard state == .paused else { return }
        guard recorder?.record() == true else {
            statusMessage = L10n.tr("subdub.error.recording_failed_generic")
            state = .failed
            return
        }
        player.isMuted = true
        player.play()
        startMetering()
        state = .recording
        statusMessage = L10n.tr("subdub.video.status.recording")
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        recorder?.stop()
        recorder = nil
        player.pause()
        player.isMuted = false
        isPreviewPlaying = false
        stopMetering()
        state = .preparing
        statusMessage = L10n.tr("subdub.video.status.validating_audio")
        Task { await validateRecordedAudio() }
    }

    func resetRecording() {
        recorder?.stop()
        recorder = nil
        removeTemporaryAudio()
        player.pause()
        player.isMuted = false
        isPreviewPlaying = false
        player.seek(to: .zero)
        stopMetering()
        state = sourceURL == nil ? .idle : .ready
            statusMessage = sourceURL == nil
            ? L10n.tr("subdub.video.status.idle")
            : L10n.tr("subdub.video.status.ready")
    }

    func toggleRecordedPreview() {
        guard hasAudio, isPlayerReady else { return }

        if isPreviewPlaying {
            player.pause()
            isPreviewPlaying = false
            statusMessage = L10n.tr("subdub.video.status.preview_paused")
            return
        }

        if playbackPosition >= max(sourceDuration - 0.1, 0) {
            player.seek(to: .zero)
            playbackPosition = 0
        }
        player.isMuted = false
        player.play()
        isPreviewPlaying = true
        statusMessage = L10n.tr("subdub.video.status.preview_playing")
    }

    func saveAudio() {
        guard let audioURL else {
            statusMessage = L10n.tr("subdub.error.audio_validation")
            return
        }
        guard let outputURL = workspace.pickAudioOutputURL(
            suggestedName: "Audio.aac",
            contentType: .mpeg4Audio
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: audioURL, to: outputURL)
            statusMessage = L10n.f("subdub.status.audio_saved", outputURL.lastPathComponent)
            workspace.reveal(outputURL)
        } catch {
            statusMessage = L10n.f("subdub.status.save_failed", error.localizedDescription)
        }
    }

    func exportVideo() {
        guard requireSubscriptionAccess() else { return }
        guard let sourceURL, let audioURL, sourceDuration > 0 else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard let outputURL = workspace.pickVideoOutputURL(
            suggestedName: "\(sourceURL.deletingPathExtension().lastPathComponent)-配音.mp4"
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }
        state = .exporting
        statusMessage = L10n.tr("subdub.video.status.exporting")
        Task {
            do {
                try await exportService.replaceAudio(
                    videoURL: sourceURL,
                    audioURL: audioURL,
                    outputURL: outputURL,
                    duration: sourceDuration
                )
                exportURL = outputURL
                state = .succeeded
                statusMessage = L10n.f("subdub.status.exported", outputURL.lastPathComponent)
                workspace.reveal(outputURL)
            } catch {
                state = .failed
                statusMessage = L10n.f("subdub.status.export_failed", error.localizedDescription)
            }
        }
    }

    private func loadVideo(from url: URL) async {
        state = .preparing
        statusMessage = L10n.tr("subdub.status.importing")
        do {
            let session = try workspace.makeSessionDirectory()
            let persistedURL = try workspace.persistInput(from: url, kind: .video, sessionDirectory: session)
            let asset = AVURLAsset(url: persistedURL)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0, try await asset.loadTracks(withMediaType: .video).isEmpty == false else {
                throw SubDubError.videoValidationFailed
            }
            recorder?.stop()
            recorder = nil
            player.pause()
            player.isMuted = false
            isPreviewPlaying = false
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            await player.seek(to: .zero)
            sessionDirectory = session
            sourceURL = persistedURL
            sourceDuration = duration.seconds
            playbackPosition = 0
            audioURL = nil
            waveformSamples.removeAll(keepingCapacity: true)
            isPreviewPlaying = false
            exportURL = nil
            isPlayerReady = true
            state = .ready
            statusMessage = L10n.f("subdub.status.imported", persistedURL.lastPathComponent)
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func requestMicrophoneAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecorder()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startRecorder()
                    } else {
                        self.state = .failed
                        self.statusMessage = L10n.tr("subdub.error.microphone_permission")
                    }
                }
            }
        default:
            state = .failed
            statusMessage = L10n.tr("subdub.error.microphone_permission")
        }
    }

    private func startRecorder() {
        guard let sessionDirectory else {
            statusMessage = L10n.tr("subdub.error.output_unavailable")
            state = .failed
            return
        }
        let url = sessionDirectory.appendingPathComponent("Audio.aac")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let nextRecorder = try AVAudioRecorder(url: url, settings: settings)
            nextRecorder.delegate = self
            nextRecorder.isMeteringEnabled = true
            guard nextRecorder.prepareToRecord(), nextRecorder.record() else {
                throw SubDubError.recordingFailed(L10n.tr("subdub.error.recording_failed_generic"))
            }
            recorder = nextRecorder
            audioURL = url
            waveformSamples = Array(repeating: 0, count: waveformSampleCount)
            isPreviewPlaying = false
            player.isMuted = true
            player.play()
            startMetering()
            state = .recording
            statusMessage = L10n.tr("subdub.video.status.recording")
        } catch {
            player.isMuted = false
            state = .failed
            statusMessage = L10n.f("subdub.status.recording_failed", error.localizedDescription)
        }
    }

    private func finishRecordingIfNeeded() {
        guard state == .recording || state == .paused else { return }
        stopRecording()
    }

    private func validateRecordedAudio() async {
        guard let audioURL else {
            state = .failed
            statusMessage = L10n.tr("subdub.error.audio_validation")
            return
        }
        do {
            try await exportService.validateAudio(audioURL)
            if let decodedSamples = try? await loadWaveformSamples(from: audioURL) {
                waveformSamples = decodedSamples
            }
            try? await prepareRecordedPreview()
            state = .finished
            statusMessage = L10n.tr("subdub.video.status.audio_ready")
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.audio_invalid", error.localizedDescription)
        }
    }

    private func removeTemporaryAudio() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        exportURL = nil
        waveformSamples.removeAll(keepingCapacity: true)
    }

    private func startMetering() {
        meteringTimer?.invalidate()
        isMetering = true
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                let normalized = pow(10, Double(power) / 20)
                self.audioLevel = min(max(normalized, 0), 1)
                self.updateLiveWaveform(self.audioLevel)
            }
        }
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        isMetering = false
        audioLevel = 0
    }

    private func updateLiveWaveform(_ level: Double) {
        guard sourceDuration > 0 else { return }
        if waveformSamples.count != waveformSampleCount {
            waveformSamples = Array(repeating: 0, count: waveformSampleCount)
        }
        let progress = min(max(playbackPosition / sourceDuration, 0), 1)
        let index = min(
            waveformSampleCount - 1,
            Int(progress * Double(waveformSampleCount - 1))
        )
        var updatedSamples = waveformSamples
        updatedSamples[index] = max(updatedSamples[index], level)
        waveformSamples = updatedSamples
    }

    private func loadWaveformSamples(from url: URL) async throws -> [Double] {
        let sampleCount = waveformSampleCount
        let targetDuration = sourceDuration
        return try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            let totalFrames = file.length
            guard totalFrames > 0 else { return [] }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: 4096
            ) else {
                return []
            }

            var samples = Array(repeating: 0.0, count: sampleCount)
            var frameOffset: AVAudioFramePosition = 0
            let channelCount = max(Int(file.processingFormat.channelCount), 1)
            let sampleRate = file.processingFormat.sampleRate
            let audioDuration = sampleRate > 0
                ? Double(totalFrames) / sampleRate
                : 0
            let audioSampleCount = targetDuration > 0 && audioDuration > 0
                ? min(
                    sampleCount,
                    max(1, Int(ceil(audioDuration / targetDuration * Double(sampleCount))))
                )
                : sampleCount

            while frameOffset < totalFrames {
                let remainingFrames = totalFrames - frameOffset
                let framesToRead = AVAudioFrameCount(
                    min(AVAudioFramePosition(buffer.frameCapacity), remainingFrames)
                )
                try file.read(into: buffer, frameCount: framesToRead)
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { break }

                if let channelData = buffer.floatChannelData {
                    for frame in 0..<frameLength {
                        let absoluteFrame = frameOffset + AVAudioFramePosition(frame)
                        let bucket = min(
                            audioSampleCount - 1,
                            Int(Double(absoluteFrame) / Double(totalFrames) * Double(audioSampleCount))
                        )
                        var power = 0.0
                        for channel in 0..<channelCount {
                            let value = Double(channelData[channel][frame])
                            power += value * value
                        }
                        samples[bucket] = max(
                            samples[bucket],
                            sqrt(power / Double(channelCount))
                        )
                    }
                }

                frameOffset += AVAudioFramePosition(frameLength)
            }

            let peak = samples.max() ?? 0
            guard peak > 0 else { return samples }
            return samples.map { min(max($0 / peak, 0), 1) }
        }.value
    }

    private func prepareRecordedPreview() async throws {
        guard let sourceURL, let audioURL else { return }
        let sourceAsset = AVURLAsset(url: sourceURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let duration = CMTime(seconds: sourceDuration, preferredTimescale: 600)

        guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw SubDubError.videoValidationFailed
        }
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )
        videoTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)

        if let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            let insertedSeconds = min(max(audioDuration.seconds, 0), sourceDuration)
            if insertedSeconds > 0 {
                try audioTrack.insertTimeRange(
                    CMTimeRange(
                        start: .zero,
                        duration: CMTime(seconds: insertedSeconds, preferredTimescale: 600)
                    ),
                    of: sourceAudioTrack,
                    at: .zero
                )
            }
        }

        player.pause()
        player.isMuted = false
        isPreviewPlaying = false
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        await player.seek(to: .zero)
    }

    private func restoreSourcePreview() async {
        guard let sourceURL else { return }
        let asset = AVURLAsset(url: sourceURL)
        player.pause()
        player.isMuted = false
        isPreviewPlaying = false
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        await player.seek(to: .zero)
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_video_export")
            onRequireSubscription?()
            return false
        }
        return true
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
