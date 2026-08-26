import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoConvertViewModel: NSObject, ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var sourceWaveformSamples: [Double] = []
    @Published private(set) var isPlayerReady = false
    @Published private(set) var isPreviewPlaying = false
    @Published private(set) var hasAudioTrack = false
    @Published private(set) var audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
    @Published var selectedFormat: VideoConversionFormat = .mp4
    @Published var selectedQuality: VideoConversionQualityPreset = .balanced
    @Published private(set) var state: VideoConversionState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var statusMessage = L10n.tr("subdub.video_conversion.status.idle")
    @Published var selectedMode: VideoConversionMode = .formatConversion

    var onConvertedVideoReady: ((URL) -> Void)?

    let player = AVPlayer()

    private let timelineSession: SubDubTimelineSession
    private let workspace = SubDubWorkspaceService()
    private let conversionService = VideoConversionService()
    private let exportService = SubDubExportService()
    private var sessionCancellable: AnyCancellable?
    private var activeTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var temporaryOutputURL: URL?
    private var standaloneSessionDirectory: URL?
    private var isUsingStandaloneSource = false
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?

    init(timelineSession: SubDubTimelineSession) {
        self.timelineSession = timelineSession
        super.init()
        sessionCancellable = timelineSession.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncFromSession()
                }
        }
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                playbackPosition = max(0, time.seconds)
                isPreviewPlaying = player.timeControlStatus == .playing
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
            }
        }
        syncFromSession()
    }

    deinit {
        activeTask?.cancel()
        audioTask?.cancel()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    var hasSource: Bool { sourceURL != nil && sourceDuration > 0 }
    var sourceName: String {
        sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video")
    }

    var sourceFormatTitle: String {
        guard let pathExtension = sourceURL?.pathExtension,
              !pathExtension.isEmpty else {
            return "—"
        }
        return pathExtension.uppercased()
    }

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

    func startConversion() {
        guard requireSubscriptionAccess() else { return }
        guard !state.isBusy, let sourceURL, sourceDuration > 0 else {
            statusMessage = L10n.tr("subdub.video_conversion.status.input_missing")
            return
        }

        guard let accessToken = DemoFlowOutputDirectoryPolicy.makeVideoCutsAccessToken() else {
            statusMessage = L10n.tr("subdub.video_conversion.status.workspace_missing")
            return
        }

        do {
            let outputDirectory = try DemoFlowOutputDirectoryPolicy.prepareVideoCutsDirectory()
            let finalURL = DemoFlowExportFileNamer.availableOutputURL(
                in: outputDirectory,
                prefix: "f",
                fileExtension: selectedFormat.fileExtension
            )
            let fileName = finalURL.lastPathComponent
            let temporaryURL = outputDirectory.appendingPathComponent(
                ".\(fileName).partial-\(UUID().uuidString)"
            )

            temporaryOutputURL = temporaryURL
            outputURL = nil
            progress = 0
            state = .converting
            statusMessage = L10n.f(
                "subdub.video_conversion.status.converting",
                L10n.tr(selectedFormat.titleKey)
            )

            let format = selectedFormat
            let quality = selectedQuality
#if DEBUG
            let onLog: (String) -> Void = { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.statusMessage = line
                }
            }
#else
            let onLog: (String) -> Void = { _ in }
#endif
            activeTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    accessToken.stop()
                    temporaryOutputURL = nil
                }
                do {
                    try await conversionService.convert(
                        sourceURL: sourceURL,
                        outputURL: temporaryURL,
                        format: format,
                        quality: quality,
                        duration: sourceDuration,
                        onProgress: { [weak self] value in
                            Task { @MainActor [weak self] in
                                self?.progress = value
                            }
                        },
                        onLog: onLog
                    )
                    guard !Task.isCancelled else { throw VideoConversionError.cancelled }
                    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                    outputURL = finalURL
                    progress = 1
                    state = .succeeded
                    statusMessage = L10n.f(
                        "subdub.video_conversion.status.succeeded",
                        finalURL.lastPathComponent
                    )
                    workspace.reveal(finalURL)
                } catch VideoConversionError.cancelled {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    state = hasSource ? .ready : .idle
                    statusMessage = L10n.tr("subdub.video_conversion.status.cancelled")
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    if Task.isCancelled {
                        state = hasSource ? .ready : .idle
                        statusMessage = L10n.tr("subdub.video_conversion.status.cancelled")
                    } else {
                        state = .failed
                        statusMessage = errorMessage(for: error)
                    }
                }
            }
        } catch {
            accessToken.stop()
            statusMessage = L10n.f(
                "subdub.video_conversion.status.failed",
                error.localizedDescription
            )
        }
    }

    func importStandaloneVideo(from url: URL) {
        conversionService.stopCurrentTask()
        activeTask?.cancel()
        activeTask = nil
        audioTask?.cancel()
        audioTask = nil
        cancelCurrentTask()
        clearStandaloneSource(deleteSession: true)
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                state = .ready
                statusMessage = L10n.tr("subdub.status.importing")
                let session = try workspace.makeSessionDirectory()
                let persistedURL = try workspace.persistInput(
                    from: url,
                    kind: .video,
                    sessionDirectory: session
                )
                let duration = try conversionService.probeSourceDuration(for: persistedURL)
                guard duration > 0 else { throw VideoConversionError.outputValidationFailed }
                standaloneSessionDirectory = session
                isUsingStandaloneSource = true
                sourceURL = persistedURL
                sourceDuration = duration
                playbackPosition = 0
                sourceWaveformSamples = []
                hasAudioTrack = false
                audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
                outputURL = nil
                progress = 0
                state = .ready
                statusMessage = L10n.f("subdub.status.imported", persistedURL.lastPathComponent)
                installPlayer(for: persistedURL)
                prepareWaveform(from: persistedURL, sessionDirectory: session)
            } catch {
                clearStandaloneSource(deleteSession: true)
                state = .failed
                statusMessage = errorMessage(for: error)
            }
        }
    }

    func cancelCurrentTask() {
        guard state.isBusy || activeTask != nil || temporaryOutputURL != nil else { return }
        conversionService.stopCurrentTask()
        activeTask?.cancel()
        activeTask = nil
        if let temporaryOutputURL {
            try? FileManager.default.removeItem(at: temporaryOutputURL)
        }
        self.temporaryOutputURL = nil
        state = hasSource ? .ready : .idle
        statusMessage = L10n.tr("subdub.video_conversion.status.cancelled")
    }

    func clearSharedVideo() {
        cancelCurrentTask()
        audioTask?.cancel()
        audioTask = nil
        clearStandaloneSource(deleteSession: true)
        clearPlayer()
        sourceURL = nil
        sourceDuration = 0
        playbackPosition = 0
        sourceWaveformSamples = []
        hasAudioTrack = false
        audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
        outputURL = nil
        progress = 0
        state = .idle
        statusMessage = L10n.tr("subdub.video_conversion.status.idle")
    }

    func revealOutput() {
        guard let outputURL else { return }
        workspace.reveal(outputURL)
    }

    private func syncFromSession() {
        guard !isUsingStandaloneSource else { return }
        let nextURL = timelineSession.videoURL
        let didChange = sourceURL != nextURL
        sourceURL = nextURL
        sourceDuration = timelineSession.sourceDuration

        let sharedSamples = timelineSession.sourceWaveformSamples
        let sharedHasAudio = timelineSession.hasSourceAudioTrack
        if sourceWaveformSamples != sharedSamples || hasAudioTrack != sharedHasAudio {
            sourceWaveformSamples = sharedSamples
            hasAudioTrack = sharedHasAudio
            if hasAudioTrack {
                audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.available")
            } else if didChange {
                audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
            }
        }

        guard didChange else { return }

        audioTask?.cancel()
        audioTask = nil
        player.pause()
        isPreviewPlaying = false
        playbackPosition = 0
        isPlayerReady = false
        if let nextURL {
            installPlayer(for: nextURL)
            hasAudioTrack = timelineSession.hasSourceAudioTrack
            audioTrackMessage = hasAudioTrack
                ? L10n.tr("subdub.video_conversion.audio_track.available")
                : L10n.tr("subdub.video_conversion.audio_track.loading")
        } else {
            clearPlayer()
            hasAudioTrack = false
            audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
        }

        outputURL = nil
        progress = 0
        if hasSource {
            state = .ready
            statusMessage = L10n.f("subdub.status.imported", nextURL?.lastPathComponent ?? "")
        } else {
            state = .idle
            statusMessage = L10n.tr("subdub.video_conversion.status.idle")
        }
    }

    func prepareForSharedImport() {
        guard isUsingStandaloneSource || activeTask != nil else { return }
        cancelCurrentTask()
        audioTask?.cancel()
        audioTask = nil
        clearStandaloneSource(deleteSession: true)
        clearPlayer()
        sourceURL = nil
        sourceDuration = 0
        playbackPosition = 0
        sourceWaveformSamples = []
        hasAudioTrack = false
        audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
        outputURL = nil
        progress = 0
        state = .idle
        statusMessage = L10n.tr("subdub.video_conversion.status.idle")
    }

    private func clearStandaloneSource(deleteSession: Bool) {
        if deleteSession, let standaloneSessionDirectory {
            try? FileManager.default.removeItem(at: standaloneSessionDirectory)
        }
        standaloneSessionDirectory = nil
        isUsingStandaloneSource = false
    }

    func togglePlayback() {
        guard isPlayerReady else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPreviewPlaying = false
        } else {
            if playbackPosition >= max(sourceDuration - 0.05, 0) {
                player.seek(to: .zero)
                playbackPosition = 0
            }
            player.play()
            isPreviewPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard isPlayerReady, sourceDuration > 0 else { return }
        let target = min(max(seconds, 0), sourceDuration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        playbackPosition = target
    }

    private func installPlayer(for url: URL) {
        guard url.pathExtension.lowercased() != "webm" else {
            clearPlayer()
            return
        }
        let asset = AVURLAsset(url: url)
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        Task { @MainActor [weak self] in
            guard let self, self.sourceURL == url else { return }
            await player.seek(to: .zero)
            isPlayerReady = true
            playbackPosition = 0
        }
    }

    private func clearPlayer() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlayerReady = false
        isPreviewPlaying = false
    }

    private func prepareWaveform(from videoURL: URL, sessionDirectory: URL) {
        audioTask?.cancel()
        let waveformURL = sessionDirectory.appendingPathComponent(
            "SourceWaveform-\(UUID().uuidString).pcm"
        )
        audioTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let samples = try await exportService.extractWaveformSamples(
                    from: videoURL,
                    outputURL: waveformURL
                )
                guard !Task.isCancelled, sourceURL == videoURL else { return }
                sourceWaveformSamples = samples
                hasAudioTrack = true
                audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.available")
            } catch {
                guard !Task.isCancelled, sourceURL == videoURL else { return }
                hasAudioTrack = false
                audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.missing")
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remaining = total % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_video_conversion")
            onRequireSubscription?()
            return false
        }
        return true
    }

    private func errorMessage(for error: Error) -> String {
        switch error {
        case VideoConversionError.inputUnavailable:
            return L10n.tr("subdub.video_conversion.error.input_unavailable")
        case VideoConversionError.dependenciesUnavailable:
            return L10n.tr("subdub.video_conversion.error.dependencies")
        case VideoConversionError.outputValidationFailed:
            return L10n.tr("subdub.video_conversion.error.output_validation")
        case let VideoConversionError.launchFailed(reason):
            return L10n.f("subdub.video_conversion.error.command", reason)
        case let VideoConversionError.commandFailed(reason):
            return L10n.f("subdub.video_conversion.error.command", reason)
        default:
            return L10n.f("subdub.video_conversion.status.failed", error.localizedDescription)
        }
    }

}
