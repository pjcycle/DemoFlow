//
//  AudioToolViewModel.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import Combine
import SwiftUI

@MainActor
final class AudioToolViewModel: ObservableObject {
    @Published var selectedTab: AudioToolTab = .extract

    var extractViewModel = AudioExtractViewModel()
    var transcodeViewModel = AudioTranscodeViewModel()
    var trimViewModel = AudioTrimViewModel()

    private var cancellables = Set<AnyCancellable>()

    init() {
        [extractViewModel.objectWillChange, transcodeViewModel.objectWillChange, trimViewModel.objectWillChange]
            .forEach { publisher in
                publisher
                    .sink { [weak self] _ in
                        self?.objectWillChange.send()
                    }
                    .store(in: &cancellables)
            }
    }

    var currentStatusText: String {
        switch selectedTab {
        case .extract:
            return extractViewModel.statusMessage
        case .transcode:
            return transcodeViewModel.statusMessage
        case .trim:
            return trimViewModel.statusMessage
        }
    }

    var currentStatusColor: Color {
        switch selectedTab {
        case .extract:
            if extractViewModel.isExtracting {
                return .yellow
            }
            return extractViewModel.latestMP3URL != nil ? .green : .white.opacity(0.85)
        case .transcode:
            if transcodeViewModel.isConverting {
                return .yellow
            }
            return transcodeViewModel.hasSuccessfulOutput ? .green : .white.opacity(0.85)
        case .trim:
            switch trimViewModel.previewStatus {
            case .playing:
                return .yellow
            case .paused:
                return .orange
            case .failed:
                return .red
            case .idle:
                return trimViewModel.hasSuccessfulOutput ? .green : .white.opacity(0.85)
            }
        }
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        extractViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        transcodeViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
        trimViewModel.configureSubscriptionAccess(
            subscriptionViewModel: subscriptionViewModel,
            onRequireSubscription: onRequireSubscription
        )
    }
}
