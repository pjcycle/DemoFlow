//
//  ContentView.swift
//  DemoFlow
//
//  Created by Jamie on 2026/4/29.
//

import SwiftUI

struct ContentView: View {
    private static let sidebarLaunchWidth: CGFloat = 200
    @ObservedObject private var appCoordinator: AppCoordinator
    @ObservedObject private var videoCuttingViewModel: VideoCuttingViewModel
    @ObservedObject private var audioExtractViewModel: AudioExtractViewModel
    @Environment(\.openWindow) private var openWindow
    private let videoCuttingWindowID: String

    @AppStorage("demoflow.sidebarCollapsed") private var sidebarCollapsedStorage = false
    @AppStorage("demoflow.sidebarWidth") private var sidebarWidthStorage = 0.0

    @State private var hasBootstrappedUIState = false
    @State private var lastKnownContainerWidth: CGFloat = 1000
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var hasUserOpenedVideoCutting = false

    init(
        appCoordinator: AppCoordinator,
        videoCuttingViewModel: VideoCuttingViewModel,
        audioExtractViewModel: AudioExtractViewModel,
        videoCuttingWindowID: String
    ) {
        self._appCoordinator = ObservedObject(wrappedValue: appCoordinator)
        self._videoCuttingViewModel = ObservedObject(wrappedValue: videoCuttingViewModel)
        self._audioExtractViewModel = ObservedObject(wrappedValue: audioExtractViewModel)
        self.videoCuttingWindowID = videoCuttingWindowID
    }

    private var audioSelectionBinding: Binding<String> {
        Binding(
            get: { appCoordinator.audioEngine.selectedSourceID ?? appCoordinator.audioEngine.sources.first?.id ?? "" },
            set: { appCoordinator.audioEngine.selectSource(withID: $0, userInitiated: true) }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: appCoordinator.isSidebarCollapsed ? 64 : clampedSidebarWidth(appCoordinator.sidebarWidth, totalWidth: width))

                if !appCoordinator.isSidebarCollapsed {
                    sidebarDivider(totalWidth: width)
                }

                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear {
                let measuredWidth = max(width, 1)
                lastKnownContainerWidth = measuredWidth
                bootstrapUIStateIfNeeded(totalWidth: measuredWidth)
                appCoordinator.bootstrap()
            }
            .onChange(of: width) { _, newWidth in
                let measuredWidth = max(newWidth, 1)
                lastKnownContainerWidth = measuredWidth
                enforceSidebarBounds(totalWidth: measuredWidth)
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
        .onChange(of: appCoordinator.isSidebarCollapsed) { _, newValue in
            sidebarCollapsedStorage = newValue
        }
        .onChange(of: appCoordinator.sidebarWidth) { _, newValue in
            sidebarWidthStorage = newValue
        }
    }

    private var sidebar: some View {
        SettingsSidebarView(
            selectedSection: Binding(
                get: { appCoordinator.selectedSettingsSection },
                set: { appCoordinator.selectedSettingsSection = $0 }
            ),
            isCollapsed: Binding(
                get: { appCoordinator.isSidebarCollapsed },
                set: { appCoordinator.isSidebarCollapsed = $0 }
            ),
            onSectionSelected: { section in
                if section == .videoCutting {
                    hasUserOpenedVideoCutting = true
                    openVideoCuttingWindow()
                }
            }
        )
    }

    private var rightPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                currentSectionView
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var currentSectionView: some View {
        switch appCoordinator.selectedSettingsSection {
        case .recording:
            RecordingSettingsView(
                appCoordinator: appCoordinator,
                audioSelectionBinding: audioSelectionBinding
            )
        case .pipCamera:
            PiPCameraSettingsView(appCoordinator: appCoordinator)
        case .screenDrawing:
            ScreenDrawingSettingsView(appCoordinator: appCoordinator)
        case .videoCutting:
            videoCuttingEntryView
        case .audioExtract:
            AudioExtractSettingsView(viewModel: audioExtractViewModel)
        case .appSettings:
            LanguageSettingsView(appCoordinator: appCoordinator)
        }
    }

    private var videoCuttingEntryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            videoCuttingHeroBanner
            videoCuttingActionCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoCuttingHeroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.9), Color.indigo.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "scissors")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("section.videoCutting.title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("section.videoCutting.subtitle"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                Circle()
                    .fill(videoCuttingViewModel.isPreparingFFmpeg ? .yellow : .white.opacity(0.85))
                    .frame(width: 8, height: 8)
                Text(videoCuttingViewModel.ffmpegPermissionStateText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.24))
            .clipShape(Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.42, green: 0.28, blue: 0.74), Color(red: 0.18, green: 0.34, blue: 0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 6)
    }

    private var videoCuttingActionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))
                Text(L10n.tr("legacy.key_124"))
                    .font(.headline)
            }

            Text(L10n.tr("legacy.key_93"))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(L10n.tr("legacy.key_124")) {
                    hasUserOpenedVideoCutting = true
                    openVideoCuttingWindow()
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.tr("ffmpeg.permission.menu.button")) {
                    videoCuttingViewModel.requestFFmpegPermissionFromMenu()
                }
                .buttonStyle(.bordered)
                .disabled(videoCuttingViewModel.isPreparingFFmpeg)
            }

            Text(L10n.tr("ffmpeg.permission.explain"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, y: 3)
    }

    private func bootstrapUIStateIfNeeded(totalWidth: CGFloat) {
        guard !hasBootstrappedUIState else { return }
        hasBootstrappedUIState = true

        appCoordinator.isSidebarCollapsed = false
        sidebarCollapsedStorage = false
        // Force a deterministic launch width each startup, ignoring stale cached widths.
        let initialWidth = defaultSidebarWidth(totalWidth: totalWidth)
        appCoordinator.sidebarWidth = initialWidth
        sidebarWidthStorage = initialWidth

        // Re-apply once after the first layout pass to override split-view remembered positions.
        DispatchQueue.main.async {
            guard !appCoordinator.isSidebarCollapsed else { return }
            let forcedWidth = defaultSidebarWidth(totalWidth: max(lastKnownContainerWidth, totalWidth))
            appCoordinator.sidebarWidth = forcedWidth
            sidebarWidthStorage = forcedWidth
        }
    }

    @ViewBuilder
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if sidebarDragStartWidth == nil {
                            sidebarDragStartWidth = appCoordinator.sidebarWidth
                        }
                        guard let startWidth = sidebarDragStartWidth else { return }
                        let nextWidth = clampedSidebarWidth(startWidth + value.translation.width, totalWidth: totalWidth)
                        if abs(nextWidth - appCoordinator.sidebarWidth) > 0.5 {
                            appCoordinator.sidebarWidth = nextWidth
                        }
                    }
                    .onEnded { _ in
                        sidebarDragStartWidth = nil
                    }
            )
    }

    private func enforceSidebarBounds(totalWidth: CGFloat) {
        guard !appCoordinator.isSidebarCollapsed else { return }
        let clamped = clampedSidebarWidth(appCoordinator.sidebarWidth, totalWidth: totalWidth)
        if abs(clamped - appCoordinator.sidebarWidth) > 0.5 {
            appCoordinator.sidebarWidth = clamped
        }
    }

    private func defaultSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        clampedSidebarWidth(Self.sidebarLaunchWidth, totalWidth: totalWidth)
    }

    private func clampedSidebarWidth(_ value: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let minWidth: CGFloat = Self.sidebarLaunchWidth
        let maxWidth: CGFloat = max(minWidth, totalWidth * 0.55)
        return min(max(value, minWidth), maxWidth)
    }

    private func openVideoCuttingWindow() {
        guard hasUserOpenedVideoCutting else { return }
        openWindow(id: videoCuttingWindowID)
    }
}
