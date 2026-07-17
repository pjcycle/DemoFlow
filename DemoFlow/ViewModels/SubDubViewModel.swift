import Combine
import Foundation

@MainActor
final class SubDubViewModel: ObservableObject {
    @Published var selectedTab: SubDubTab = .videoDubbing

    let videoDubbingViewModel: VideoDubbingViewModel
    let aiVoiceoverViewModel: AIVoiceoverViewModel
    let subtitleSyncViewModel: SubtitleSyncViewModel

    init() {
        videoDubbingViewModel = VideoDubbingViewModel()
        aiVoiceoverViewModel = AIVoiceoverViewModel()
        subtitleSyncViewModel = SubtitleSyncViewModel()
    }

    var currentStatusText: String {
        switch selectedTab {
        case .videoDubbing: return videoDubbingViewModel.statusMessage
        case .aiVoiceover: return aiVoiceoverViewModel.statusMessage
        case .subtitleSync: return subtitleSyncViewModel.statusMessage
        }
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        videoDubbingViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        aiVoiceoverViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        subtitleSyncViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
    }
}
