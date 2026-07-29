import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SubDubViewModel: ObservableObject {
    @Published var selectedTab: SubDubTab = .videoDubbing

    let videoDubbingViewModel: VideoDubbingViewModel
    let subtitleBurnViewModel: SubtitleBurnViewModel
    let audioReplacementViewModel: AudioReplacementViewModel
    let timelineSession: SubDubTimelineSession

    private let workspace = SubDubWorkspaceService()
    private var timelineCancellable: AnyCancellable?

    init() {
        timelineSession = SubDubTimelineSession()
        videoDubbingViewModel = VideoDubbingViewModel()
        subtitleBurnViewModel = SubtitleBurnViewModel(timelineSession: timelineSession)
        audioReplacementViewModel = AudioReplacementViewModel(timelineSession: timelineSession)
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

    func importVideo(from url: URL) {
        subtitleBurnViewModel.importVideo(from: url)
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
}
