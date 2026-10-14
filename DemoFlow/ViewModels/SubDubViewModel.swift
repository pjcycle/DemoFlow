import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SubDubViewModel: ObservableObject {
    @Published var selectedTab: SubDubTab = .videoDubbing

    let videoDubbingViewModel: VideoDubbingViewModel
    let videoConversionViewModel: VideoConvertViewModel
    let watermarkRemovalViewModel: WatermarkRemovalViewModel
    let subtitleBurnViewModel: SubtitleBurnViewModel
    let audioReplacementViewModel: AudioReplacementViewModel
    let videoCompositionViewModel: VideoCompositionViewModel
    let timelineSession: SubDubTimelineSession

    private let workspace = SubDubWorkspaceService()
    private var timelineCancellable: AnyCancellable?
    private var pendingWatermarkReloadURL: URL?
    private var pendingCompositionAdditionalURLs: [URL] = []

    init() {
        timelineSession = SubDubTimelineSession()
        videoDubbingViewModel = VideoDubbingViewModel()
        videoConversionViewModel = VideoConvertViewModel(timelineSession: timelineSession)
        watermarkRemovalViewModel = WatermarkRemovalViewModel(timelineSession: timelineSession)
        subtitleBurnViewModel = SubtitleBurnViewModel(timelineSession: timelineSession)
        audioReplacementViewModel = AudioReplacementViewModel(timelineSession: timelineSession)
        videoCompositionViewModel = VideoCompositionViewModel()
        watermarkRemovalViewModel.onProcessedVideoReady = { [weak self] url in
            self?.replaceSharedVideoAfterWatermarkRemoval(with: url)
        }
        videoCompositionViewModel.onCompositionCompleted = { [weak self] url in
            self?.replaceSharedVideoAfterComposition(with: url)
        }
        subtitleBurnViewModel.onVideoImportResult = { [weak self] url, result in
            self?.handleVideoImportResult(url: url, result: result)
        }
        timelineCancellable = timelineSession.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.adoptSharedVideoIfNeeded()
                }
            }
    }

    var currentStatusText: String {
        switch selectedTab {
        case .videoDubbing: return videoDubbingViewModel.statusMessage
        case .videoConversion:
            return videoConversionViewModel.selectedMode == .watermarkRemoval
                ? watermarkRemovalViewModel.statusMessage
                : videoConversionViewModel.statusMessage
        case .subtitleBurning: return subtitleBurnViewModel.statusMessage
        case .audioReplacement: return audioReplacementViewModel.statusMessage
        case .videoComposition: return videoCompositionViewModel.statusMessage
        }
    }

    func importVideoByPanel() {
        guard let url = workspace.pickVideoURL() else {
            subtitleBurnViewModel.reportImportCancelled()
            return
        }
        importVideo(from: url)
    }

    func importVideoForConversionByPanel() {
        guard let url = workspace.pickVideoConversionURL() else {
            videoConversionViewModel.cancelCurrentTask()
            return
        }
        importVideo(from: url)
    }

    func importVideo(from url: URL) {
        videoConversionViewModel.cancelCurrentTask()
        watermarkRemovalViewModel.cancelCurrentTask()
        if url.pathExtension.lowercased() == "webm" {
            videoDubbingViewModel.clearSharedVideo()
            subtitleBurnViewModel.removeVideo()
            videoConversionViewModel.importStandaloneVideo(from: url)
            return
        }
        videoConversionViewModel.prepareForSharedImport()
        subtitleBurnViewModel.importVideo(from: url)
    }

    // MARK: - Video composition shared import

    /// Import the first composition source through the normal shared-video
    /// pipeline so all five SubDub tabs immediately see the same playable
    /// video. Additional selections are queued until that shared session is
    /// ready, then appended only to the composition timeline.
    func importCompositionByPanel() {
        guard let urls = workspace.pickVideoCompositionURLs(), !urls.isEmpty else {
            videoCompositionViewModel.reportImportCancelled()
            return
        }
        importCompositionVideos(urls)
    }

    func importCompositionDroppedProviders(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let identifiers = [
            UTType.mpeg4Movie.identifier,
            UTType.quickTimeMovie.identifier,
            UTType.movie.identifier,
            UTType.fileURL.identifier
        ]
        let group = DispatchGroup()
        var loaded: [(Int, URL)] = []
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            guard let identifier = identifiers.first(where: {
                provider.hasItemConformingToTypeIdentifier($0)
            }) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                if let url {
                    lock.lock()
                    loaded.append((index, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = loaded.sorted { $0.0 < $1.0 }.map(\.1)
            self?.importCompositionVideos(urls)
        }
    }

    func importCompositionVideos(_ urls: [URL]) {
        let supported = urls.filter {
            ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased())
        }
        guard !supported.isEmpty else {
            videoCompositionViewModel.reportUnsupportedImport()
            return
        }

        // If another tab already owns a shared source, seed that source first
        // even when the composition tab has not been shown yet. New imports
        // then become appended composition clips instead of replacing the
        // shared video.
        adoptSharedVideoIfNeeded()
        if videoCompositionViewModel.hasSource {
            videoCompositionViewModel.importVideos(urls: supported)
            return
        }

        let first = supported[0]
        pendingCompositionAdditionalURLs.append(contentsOf: supported.dropFirst())
        importVideo(from: first)
    }

    /// Refresh the composition tab from the current shared source. Called on
    /// tab appearance as well as timeline-session changes so switching tabs
    /// never leaves a stale preview behind.
    func synchronizeCompositionWithSharedVideo() {
        adoptSharedVideoIfNeeded()
    }

    func importConvertedVideoIntoSharedSession() {
        guard let url = videoConversionViewModel.outputURL else { return }
        importVideo(from: url)
    }

    func replaceSharedVideoAfterWatermarkRemoval(with url: URL) {
        // A watermark-processed file is a new source. Stop every dependent workflow
        // before recreating the shared timeline session so no draft remains bound to it.
        videoDubbingViewModel.stopPlaybackForSourceReplacement()
        videoConversionViewModel.cancelCurrentTask()
        subtitleBurnViewModel.cancelCurrentTask()
        subtitleBurnViewModel.stopPlaybackForSourceReplacement()
        audioReplacementViewModel.cancelCurrentTask()
        audioReplacementViewModel.stopPlayback()
        guard let reloadAccessToken = DemoFlowOutputDirectoryPolicy.makeVideoCutsAccessToken() else {
            watermarkRemovalViewModel.markReloadFailed()
            return
        }
        pendingWatermarkReloadURL = url.standardizedFileURL
        watermarkRemovalViewModel.prepareForProcessedVideoReload()
        videoConversionViewModel.selectedMode = .formatConversion
        selectedTab = .videoConversion
        videoConversionViewModel.prepareForSharedImport()
        // Keep the workspace scope alive inside the import task while the finished
        // file is copied into the new shared session.
        subtitleBurnViewModel.importVideo(
            from: url.standardizedFileURL,
            retainingAccessToken: reloadAccessToken
        )
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let identifiers = [
            UTType.movie.identifier,
            UTType.mpeg4Movie.identifier,
            UTType.quickTimeMovie.identifier,
            UTType.plainText.identifier,
            UTType.fileURL.identifier
        ]
        guard let identifier = identifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else { return }

        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if ["srt", "vtt"].contains(url.pathExtension.lowercased()) {
                    self.subtitleBurnViewModel.importSubtitle(from: url)
                } else {
                    self.importVideo(from: url)
                }
            }
        }
    }

    func removeSharedVideo() {
        pendingCompositionAdditionalURLs.removeAll()
        videoCompositionViewModel.clearProject()
        videoConversionViewModel.clearSharedVideo()
        watermarkRemovalViewModel.resetForNewSharedVideo()
        videoDubbingViewModel.clearSharedVideo()
        subtitleBurnViewModel.removeVideo()
    }

    func replaceSharedVideoAfterComposition(with url: URL) {
        guard let accessToken = DemoFlowOutputDirectoryPolicy.makeVideoCutsAccessToken() else {
            videoCompositionViewModel.reportWorkspaceUnavailable()
            return
        }

        // Keep the previous shared session intact until the new import
        // succeeds.  This avoids losing the old source on an import failure;
        // each tab's source-bound draft is reset by its session observer once
        // the new shared project is configured below.
        videoDubbingViewModel.stopPlaybackForSourceReplacement()
        videoConversionViewModel.cancelCurrentTask()
        subtitleBurnViewModel.cancelCurrentTask()
        subtitleBurnViewModel.stopPlaybackForSourceReplacement()
        audioReplacementViewModel.cancelCurrentTask()
        audioReplacementViewModel.stopPlayback()
        videoConversionViewModel.prepareForSharedImport()
        subtitleBurnViewModel.importVideo(
            from: url.standardizedFileURL,
            retainingAccessToken: accessToken
        )
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        videoDubbingViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        videoConversionViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        watermarkRemovalViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        subtitleBurnViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        audioReplacementViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        videoCompositionViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
    }

    private func adoptSharedVideoIfNeeded() {
        guard let videoURL = timelineSession.videoURL,
              let sessionDirectory = timelineSession.sessionDirectory,
              timelineSession.sourceDuration > 0 else {
            return
        }
        videoDubbingViewModel.adoptSharedVideo(
            url: videoURL,
            duration: timelineSession.sourceDuration,
            sessionDirectory: sessionDirectory,
            sourceAudioURL: timelineSession.sourceAudioURL,
            sourceWaveformSamples: timelineSession.sourceWaveformSamples
        )
        videoCompositionViewModel.adoptSharedVideo(
            url: videoURL,
            duration: timelineSession.sourceDuration,
            sessionDirectory: sessionDirectory,
            hasAudioTrack: timelineSession.hasSourceAudioTrack
        )
        flushPendingCompositionAdditionalURLs()
    }

    private func flushPendingCompositionAdditionalURLs() {
        guard !pendingCompositionAdditionalURLs.isEmpty,
              timelineSession.videoURL != nil,
              videoCompositionViewModel.hasSource else { return }
        let pending = pendingCompositionAdditionalURLs
        pendingCompositionAdditionalURLs.removeAll()
        videoCompositionViewModel.importVideos(urls: pending)
    }

    private func handleVideoImportResult(url: URL, result: Result<Void, Error>) {
        if url.standardizedFileURL == pendingWatermarkReloadURL {
            pendingWatermarkReloadURL = nil
            switch result {
            case .success:
                watermarkRemovalViewModel.markCurrentVideoAsProcessed()
            case .failure:
                watermarkRemovalViewModel.markReloadFailed()
            }
        }
        if case .success = result {
            // The subtitle-burn importer is the owner of the shared session.
            // Once it succeeds, mirror that source into composition and flush
            // any additional files selected in the same import operation.
            adoptSharedVideoIfNeeded()
        } else if !pendingCompositionAdditionalURLs.isEmpty {
            // The first shared import failed or was cancelled; do not carry
            // stale append selections into the next composition import.
            pendingCompositionAdditionalURLs.removeAll()
        }
    }
}
