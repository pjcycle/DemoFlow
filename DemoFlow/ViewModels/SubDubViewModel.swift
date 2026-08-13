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
    let timelineSession: SubDubTimelineSession

    private let workspace = SubDubWorkspaceService()
    private var timelineCancellable: AnyCancellable?
    private var pendingWatermarkReloadURL: URL?

    init() {
        timelineSession = SubDubTimelineSession()
        videoDubbingViewModel = VideoDubbingViewModel()
        videoConversionViewModel = VideoConvertViewModel(timelineSession: timelineSession)
        watermarkRemovalViewModel = WatermarkRemovalViewModel(timelineSession: timelineSession)
        subtitleBurnViewModel = SubtitleBurnViewModel(timelineSession: timelineSession)
        audioReplacementViewModel = AudioReplacementViewModel(timelineSession: timelineSession)
        watermarkRemovalViewModel.onProcessedVideoReady = { [weak self] url in
            self?.replaceSharedVideoAfterWatermarkRemoval(with: url)
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
        videoConversionViewModel.clearSharedVideo()
        watermarkRemovalViewModel.resetForNewSharedVideo()
        videoDubbingViewModel.clearSharedVideo()
        subtitleBurnViewModel.removeVideo()
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
    }

    private func handleVideoImportResult(url: URL, result: Result<Void, Error>) {
        guard url.standardizedFileURL == pendingWatermarkReloadURL else { return }
        pendingWatermarkReloadURL = nil
        if case .failure = result {
            watermarkRemovalViewModel.markReloadFailed()
        }
    }
}
