//
//  DemoFlowApp.swift
//  DemoFlow
//
//  Created by Jamie on 2026/4/29.
//

import AppKit
import AppIntents
import SwiftUI

@main
struct DemoFlowApp: App {
    private static let videoCuttingWindowID = "video-cutting-window"
    @NSApplicationDelegateAdaptor(DemoFlowAppDelegate.self) private var appDelegate
    @StateObject private var appCoordinator = AppCoordinator()
    @StateObject private var videoCuttingViewModel = VideoCuttingViewModel()
    @StateObject private var audioToolViewModel = AudioToolViewModel()
    @StateObject private var subDubViewModel = SubDubViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("DemoFlow", id: "main-window") {
            ContentView(
                appCoordinator: appCoordinator,
                videoCuttingViewModel: videoCuttingViewModel,
                audioToolViewModel: audioToolViewModel,
                subDubViewModel: subDubViewModel,
                videoCuttingWindowID: Self.videoCuttingWindowID
            )
            .environment(\.locale, appCoordinator.appLocale)
            .onAppear {
                appDelegate.configure(appCoordinator: appCoordinator)
                configureSubscriptionGatesIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                appDelegate.configure(appCoordinator: appCoordinator)
                appCoordinator.refreshLanguageIfNeeded()
                configureSubscriptionGatesIfNeeded()
            }
        }
        // Show the single background control window at launch. It is never
        // auto-hidden after becoming visible.
        .restorationBehavior(.disabled)

        Window(L10n.tr("legacy.key_157"), id: Self.videoCuttingWindowID) {
            VideoCuttingModalView(
                viewModel: videoCuttingViewModel,
                appCoordinator: appCoordinator,
                windowID: Self.videoCuttingWindowID
            )
            .environment(\.locale, appCoordinator.appLocale)
            .id(appCoordinator.resolvedLanguage.rawValue)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }

    private func configureSubscriptionGatesIfNeeded() {
        let coordinator = appCoordinator
        let openPaywall = { [weak coordinator] in
            if let coordinator {
                coordinator.openSubscriptionWindow()
            }
        }
        videoCuttingViewModel.configureSubscriptionAccess(
            subscriptionViewModel: coordinator.subscriptionViewModel,
            onRequireSubscription: openPaywall
        )
        audioToolViewModel.configureSubscriptionAccess(
            subscriptionViewModel: coordinator.subscriptionViewModel,
            onRequireSubscription: openPaywall
        )
        subDubViewModel.configureSubscriptionAccess(
            subscriptionViewModel: coordinator.subscriptionViewModel,
            onRequireSubscription: openPaywall
        )
    }
}

@MainActor
final class DemoFlowAppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarRecordingController()
    private weak var appCoordinator: AppCoordinator?
    private var didRequestInitialMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController.install()
    }

    func configure(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        menuBarController.configure(appCoordinator: appCoordinator)
        guard !didRequestInitialMainWindow else { return }
        didRequestInitialMainWindow = true
        // Explicitly open the singleton background control window after the
        // SwiftUI scene has installed its notification receiver.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .demoFlowShouldOpenMainWindow, object: nil)
        }
    }
}
