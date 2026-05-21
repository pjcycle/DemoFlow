//
//  PiPCameraSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AVFoundation
import AppKit
import SwiftUI

struct PiPCameraSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var pipRuntime: PiPPreviewRuntime
    @State private var showingDiagnostics = false

    init(appCoordinator: AppCoordinator) {
        self._appCoordinator = ObservedObject(wrappedValue: appCoordinator)
        self._pipRuntime = ObservedObject(wrappedValue: appCoordinator.pipPreviewRuntime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            previewCard
            deviceCard
            windowCard
            audioMonitorCard

            if let infoMessage = pipRuntime.infoMessage, !infoMessage.isEmpty {
                card(title: L10n.tr("legacy.key_31"), icon: "info.circle") {
                    Text(L10n.f("fmt.device.status", infoMessage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.9), Color.blue.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("section.pipCamera.title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("section.pipCamera.subtitle"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            Spacer(minLength: 10)
            statusChip
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.55, blue: 0.73), Color(red: 0.17, green: 0.24, blue: 0.62)],
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

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(appCoordinator.pipStatusMessage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24))
        .clipShape(Capsule())
    }

    private var previewCard: some View {
        card(title: L10n.tr("legacy.key_222"), icon: "display") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(previewConsoleSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("pip.film.card.subtitle"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("pip.hotkey.tip"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                previewStateBadge
            }

            HStack(spacing: 12) {
                if appCoordinator.isPiPPreviewVisible {
                    Button(L10n.tr("legacy.pip_25")) {
                        appCoordinator.hidePiPPreview()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(L10n.tr("legacy.pip_12")) {
                        appCoordinator.activatePiPPreview()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if appCoordinator.canStartPiPFilmRecording {
                    Button(L10n.tr("pip.film.action.start")) {
                        appCoordinator.startPiPFilmRecording()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appCoordinator.canStartPiPFilmRecording)
                } else {
                    Button(L10n.tr("pip.film.action.stop")) {
                        appCoordinator.stopPiPFilmRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!appCoordinator.canStopPiPFilmRecording)
                }

                Button(L10n.tr("pip.film.action.open_folder")) {
                    appCoordinator.openPiPRecordingsDirectory()
                }
                .buttonStyle(.bordered)
            }

            Text(filmStatusSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let outputURL = appCoordinator.lastPiPFilmOutputURL {
                Text(L10n.f("pip.film.latest_output", outputURL.lastPathComponent))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deviceCard: some View {
        card(title: L10n.tr("legacy.key_199"), icon: "camera") {
            Picker(L10n.tr("legacy.key_142"), selection: cameraSelectionBinding) {
                ForEach(pipRuntime.sources) { source in
                    let label = source.badgeText.isEmpty ? source.name : "\(source.name) (\(source.badgeText))"
                    Text(label).tag(source.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!isCameraAuthorized || pipRuntime.sources.isEmpty)

            Picker(L10n.tr("legacy.pip_9"), selection: cameraAudioSelectionBinding) {
                ForEach(pipRuntime.audioSources) { source in
                    let label = source.badgeText.isEmpty ? source.name : "\(source.name) (\(source.badgeText))"
                    Text(label).tag(source.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!isCameraAudioAuthorized || pipRuntime.audioSources.isEmpty)

            Text(selectedDeviceSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(L10n.tr("legacy.key_31")) {
                    pipRuntime.refreshSources()
                    pipRuntime.refreshAudioSources()
                }
                if !isCameraAuthorized {
                    Button(L10n.tr("legacy.key_203")) { pipRuntime.requestCameraAccess() }
                }
                if !isCameraAudioAuthorized {
                    Button(L10n.tr("legacy.pip_27")) { pipRuntime.requestMicrophoneAccess() }
                }
                Button(L10n.tr("legacy.key_125")) { openPrivacySettings() }
                Button(showingDiagnostics ? L10n.tr("legacy.key_200") : L10n.tr("legacy.key_208")) {
                    runInAppDiagnostics()
                }
                .disabled(showingDiagnostics)
            }

            if needsPermissionRecovery {
                permissionRecoveryGuide
            }

            if pipRuntime.sources.isEmpty {
                statusBanner(
                    title: isCameraAuthorized ? L10n.tr("legacy.key_160") : L10n.tr("legacy.key_139"),
                    detail: cameraEmptyStateText
                )
            } else if pipRuntime.sources.allSatisfy({ !$0.isAvailable }) {
                statusBanner(
                    title: L10n.tr("legacy.key_143"),
                    detail: L10n.tr("legacy.iphone_continuity_camera")
                )
            }

            Text(L10n.f("fmt.pip.current_status", appCoordinator.pipStatusMessage))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var windowCard: some View {
        card(title: L10n.tr("legacy.key_187"), icon: "rectangle.on.rectangle") {
            Toggle(L10n.tr("legacy.key_212"), isOn: Binding(
                get: { appCoordinator.pipWindowConfig.isAlwaysOnTop },
                set: { newValue in
                    var next = appCoordinator.pipWindowConfig
                    next.isAlwaysOnTop = newValue
                    appCoordinator.pipWindowConfig = next
                }
            ))

            HStack(alignment: .center, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { appCoordinator.pipWindowConfig.isTitleBarVisible },
                    set: { newValue in
                        var next = appCoordinator.pipWindowConfig
                        next.isTitleBarVisible = newValue
                        appCoordinator.pipWindowConfig = next
                    }
                )) {
                    Text(L10n.tr("legacy.pip_4"))
                        .font(.body.weight(.medium))
                }
                .toggleStyle(.checkbox)

                TextField(
                    PiPWindowConfig.defaultWindowTitle,
                    text: Binding(
                        get: { appCoordinator.pipWindowConfig.windowTitle },
                        set: { newValue in
                            var next = appCoordinator.pipWindowConfig
                            next.windowTitle = newValue
                            appCoordinator.pipWindowConfig = next
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            }

            Picker(L10n.tr("legacy.key_207"), selection: Binding(
                get: { appCoordinator.pipWindowConfig.frameStyle },
                set: { newValue in
                    var next = appCoordinator.pipWindowConfig
                    next.frameStyle = newValue
                    appCoordinator.pipWindowConfig = next
                }
            )) {
                ForEach(PiPWindowFrameStyle.allCases, id: \.self) { style in
                    Text(style.displayTitle).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Picker(L10n.tr("legacy.key_184"), selection: Binding(
                get: { appCoordinator.pipAspectRatio },
                set: { appCoordinator.pipAspectRatio = $0 }
            )) {
                ForEach(PiPAspectRatio.allCases) { ratio in
                    Text(ratio.displayTitle).tag(ratio)
                }
            }
            .pickerStyle(.segmented)

            Text(
                L10n.f(
                    "fmt.pip.current_layout",
                    appCoordinator.pipLayout.normalizedRect.minX,
                    appCoordinator.pipLayout.normalizedRect.minY,
                    appCoordinator.pipLayout.normalizedRect.width,
                    appCoordinator.pipLayout.normalizedRect.height
                )
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("fmt.pip.current_title", appCoordinator.pipWindowConfig.resolvedWindowTitle))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.f("fmt.pip.current_frame", appCoordinator.pipWindowConfig.frameStyle.displayTitle))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.tr("legacy.k_240x240"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var audioMonitorCard: some View {
        card(title: L10n.tr("legacy.pip_8"), icon: "waveform") {
            Toggle(L10n.tr("legacy.key_223"), isOn: Binding(
                get: { appCoordinator.pipAudioPreviewConfig.isPreviewMuted },
                set: { newValue in
                    var next = appCoordinator.pipAudioPreviewConfig
                    next.isPreviewMuted = newValue
                    appCoordinator.pipAudioPreviewConfig = next
                }
            ))

            HStack(spacing: 10) {
                Text(L10n.tr("legacy.key_224"))
                Slider(value: Binding(
                    get: { appCoordinator.pipAudioPreviewConfig.previewVolume },
                    set: { newValue in
                        var next = appCoordinator.pipAudioPreviewConfig
                        next.previewVolume = newValue
                        appCoordinator.pipAudioPreviewConfig = next
                    }
                ), in: 0...1)
                Text("\(Int(appCoordinator.pipAudioPreviewConfig.clampedVolume * 100))")
                    .frame(width: 38, alignment: .trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AudioLevelMeterView(level: pipRuntime.previewAudioLevel)
                .frame(height: 12)

            Text(
                L10n.f(
                    "legacy.pip_status_line_with_level",
                    appCoordinator.pipAudioPreviewConfig.isPreviewMuted ? L10n.tr("legacy.key_218") : L10n.tr("legacy.key_185"),
                    Int(pipRuntime.previewAudioLevel * 100)
                )
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var cameraSelectionBinding: Binding<String> {
        Binding(
            get: { pipRuntime.selectedSourceID ?? pipRuntime.sources.first?.id ?? "" },
            set: { pipRuntime.selectSource(withID: $0) }
        )
    }

    private var cameraAudioSelectionBinding: Binding<String> {
        Binding(
            get: { pipRuntime.selectedAudioSourceID ?? pipRuntime.audioSources.first?.id ?? "" },
            set: { pipRuntime.selectAudioSource(withID: $0) }
        )
    }

    private var previewStateBadge: some View {
        let label: String
        let tint: Color
        if appCoordinator.isPiPPreviewVisible {
            label = L10n.tr("legacy.key_221")
            tint = .green
        } else if appCoordinator.enableCameraPiP {
            label = L10n.tr("legacy.key_86")
            tint = .blue
        } else {
            label = L10n.tr("legacy.key_161")
            tint = .secondary
        }

        return Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }

    private var previewConsoleSummary: String {
        if appCoordinator.isPiPPreviewVisible {
            return L10n.tr("legacy.key_118")
        }
        if appCoordinator.enableCameraPiP {
            return L10n.tr("legacy.pip")
        }
        return L10n.tr("legacy.pip_17")
    }

    private var filmStatusSummary: String {
        switch appCoordinator.pipFilmState {
        case .idle:
            return L10n.tr("pip.film.status.idle")
        case .preparing:
            return L10n.tr("pip.film.status.preparing")
        case .recording:
            return L10n.tr("pip.film.status.recording")
        case .stopping:
            return L10n.tr("pip.film.status.stopping")
        case let .failed(reason):
            return L10n.f("pip.film.status.failed", reason)
        }
    }

    private var selectedDeviceSummary: String {
        let selectedCamera = pipRuntime.sources.first(where: {
            $0.id == pipRuntime.selectedSourceID
        })?.name ?? L10n.tr("legacy.key_167")
        let selectedMic = pipRuntime.audioSources.first(where: {
            $0.id == pipRuntime.selectedAudioSourceID
        })?.name ?? L10n.tr("legacy.key_167")
        return L10n.f("fmt.pip.current_device_summary", selectedCamera, selectedMic)
    }

    private var needsPermissionRecovery: Bool {
        pipRuntime.authorizationStatus != .authorized
            || pipRuntime.microphoneAuthorizationStatus != .authorized
            || (pipRuntime.lastVideoEnumeratedCount == 0 && pipRuntime.lastAudioEnumeratedCount == 0)
    }

    private var statusColor: Color {
        if appCoordinator.isPiPPreviewVisible { return .green }
        if appCoordinator.enableCameraPiP { return .yellow }
        return .white.opacity(0.85)
    }

    @ViewBuilder
    private var permissionRecoveryGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("legacy.key_117"))
                .font(.subheadline.weight(.semibold))
            Text(L10n.tr("legacy.k_1_pip"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.tr("legacy.k_2_demoflow"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.tr("legacy.k_3_2"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
        )
    }

    private var isCameraAuthorized: Bool {
        pipRuntime.authorizationStatus == .authorized
    }

    private var isCameraAudioAuthorized: Bool {
        pipRuntime.microphoneAuthorizationStatus == .authorized
    }

    private var cameraEmptyStateText: String {
        switch pipRuntime.authorizationStatus {
        case .notDetermined:
            return L10n.tr("legacy.key_97")
        case .denied:
            return L10n.tr("legacy.demoflow_6")
        case .restricted:
            return L10n.tr("legacy.pip_19")
        case .authorized:
            return L10n.tr("legacy.macos_continuity")
        @unknown default:
            return L10n.tr("legacy.key_141")
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))
                Text(title)
                    .font(.headline)
            }

            content()
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

    @ViewBuilder
    private func statusBanner(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func runInAppDiagnostics() {
        showingDiagnostics = true
        pipRuntime.refreshSources()
        pipRuntime.refreshAudioSources()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            pipRuntime.refreshSources()
            pipRuntime.refreshAudioSources()
            showingDiagnostics = false
        }
    }
}
