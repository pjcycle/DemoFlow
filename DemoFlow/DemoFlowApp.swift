//
//  DemoFlowApp.swift
//  DemoFlow
//
//  Created by Jamie on 2026/4/29.
//

import SwiftUI

@main
struct DemoFlowApp: App {
    private static let videoCuttingWindowID = "video-cutting-window"
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

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Button(appCoordinator.recorderState.isRecording ? L10n.tr("legacy.key_15") : L10n.tr("legacy.key_98")) {
                    if appCoordinator.recorderState.isRecording {
                        appCoordinator.stopRecordingAndRestoreMonitoring()
                    } else {
                        appCoordinator.startRecordingFromCurrentConfig()
                    }
                }
                .disabled(appCoordinator.recorderState.isBusy)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.f("fmt.menu.recording_status", appCoordinator.statusMessage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(L10n.f("fmt.menu.pip_status", appCoordinator.pipStatusMessage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Divider()
                Button(L10n.tr("legacy.key_154")) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows {
                        if window.isMiniaturized {
                            window.deminiaturize(nil)
                        }
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                Button(L10n.tr("legacy.key_209")) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        } label: {
            Label(
                "DemoFlow",
                systemImage: appCoordinator.recorderState.isRecording ? "record.circle.fill" : "record.circle"
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            appCoordinator.refreshLanguageIfNeeded()
        }
    }
}
