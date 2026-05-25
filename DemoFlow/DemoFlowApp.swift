//
//  DemoFlowApp.swift
//  DemoFlow
//
//  Created by Jamie on 2026/4/29.
//

import AppKit
import SwiftUI

@main
struct DemoFlowApp: App {
    private static let videoCuttingWindowID = "video-cutting-window"
    @NSApplicationDelegateAdaptor(DemoFlowAppDelegate.self) private var appDelegate
    @StateObject private var appCoordinator = AppCoordinator()
    @StateObject private var videoCuttingViewModel = VideoCuttingViewModel()
    @StateObject private var audioExtractViewModel = AudioExtractViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("DemoFlow", id: "main-window") {
            ContentView(
                appCoordinator: appCoordinator,
                videoCuttingViewModel: videoCuttingViewModel,
                audioExtractViewModel: audioExtractViewModel,
                videoCuttingWindowID: Self.videoCuttingWindowID
            )
            .environment(\.locale, appCoordinator.appLocale)
            .onAppear {
                appDelegate.configure(appCoordinator: appCoordinator)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                appDelegate.configure(appCoordinator: appCoordinator)
                appCoordinator.refreshLanguageIfNeeded()
            }
        }

        Window(L10n.tr("legacy.key_157"), id: Self.videoCuttingWindowID) {
            VideoCuttingModalView(
                viewModel: videoCuttingViewModel,
                appCoordinator: appCoordinator,
                windowID: Self.videoCuttingWindowID
            )
            .environment(\.locale, appCoordinator.appLocale)
            .id(appCoordinator.resolvedLanguage.rawValue)
        }
        .defaultSize(width: 1320, height: 860)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class DemoFlowAppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarRecordingController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController.install()
    }

    func configure(appCoordinator: AppCoordinator) {
        menuBarController.configure(appCoordinator: appCoordinator)
    }
}
