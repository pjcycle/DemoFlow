//
//  MicrophoneSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AVFoundation
import SwiftUI

struct MicrophoneSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    let audioSelectionBinding: Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(L10n.tr("legacy.key_228"), subtitle: L10n.tr("legacy.key_206"))

            card {
                Picker(L10n.tr("legacy.key_205"), selection: audioSelectionBinding) {
                    ForEach(appCoordinator.audioEngine.sources) { source in
                        let label = source.badgeText.isEmpty ? source.name : "\(source.name) (\(source.badgeText))"
                        Text(label).tag(source.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!isAudioAuthorized || appCoordinator.audioEngine.sources.isEmpty)

                HStack(spacing: 12) {
                    Button(L10n.tr("legacy.key_31")) { appCoordinator.audioEngine.refreshSources() }

                    Button(appCoordinator.audioEngine.isMonitoring ? L10n.tr("legacy.key_18") : L10n.tr("legacy.key_100")) {
                        if appCoordinator.audioEngine.isMonitoring {
                            appCoordinator.audioEngine.stopMonitoring()
                        } else {
                            appCoordinator.audioEngine.startMonitoringIfNeeded()
                        }
                    }
                    .disabled(!isAudioAuthorized || appCoordinator.audioEngine.sources.isEmpty)

                    if !isAudioAuthorized {
                        Button(L10n.tr("legacy.key_204")) { appCoordinator.audioEngine.requestMicrophoneAccess() }
                    }
                }

                AudioLevelMeterView(level: appCoordinator.audioEngine.level)
                    .frame(height: 12)
                Text(L10n.f("fmt.input.level", Int(appCoordinator.audioEngine.level * 100)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            card {
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

                AudioLevelMeterView(level: appCoordinator.pipPreviewRuntime.previewAudioLevel)
                    .frame(height: 12)
                Text(
                    L10n.f(
                        "legacy.pip_status_line_with_level",
                        appCoordinator.pipAudioPreviewConfig.isPreviewMuted ? L10n.tr("legacy.key_217") : L10n.tr("legacy.key_185"),
                        Int(appCoordinator.pipPreviewRuntime.previewAudioLevel * 100)
                    )
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isAudioAuthorized: Bool {
        appCoordinator.audioEngine.authorizationStatus == .authorized
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}
