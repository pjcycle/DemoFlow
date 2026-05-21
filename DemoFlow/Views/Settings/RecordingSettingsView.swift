//
//  RecordingSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AVFoundation
import AppKit
import SwiftUI

struct RecordingSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    let audioSelectionBinding: Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            recordingControlCard
            microphoneCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.9), Color.pink.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "record.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("section.recording.title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("section.recording.subtitle"))
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
                colors: [Color(red: 0.78, green: 0.22, blue: 0.18), Color(red: 0.30, green: 0.14, blue: 0.45)],
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
                .fill(appCoordinator.recorderState.isRecording ? .red : .white.opacity(0.85))
                .frame(width: 8, height: 8)
            Text(appCoordinator.statusMessage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24))
        .clipShape(Capsule())
    }

    private var recordingControlCard: some View {
        card(title: L10n.tr("legacy.key_102"), icon: "record.circle.fill") {
            HStack(spacing: 12) {
                Button(actionButtonTitle) {
                    if appCoordinator.recorderState.isRecording {
                        appCoordinator.stopRecordingAndRestoreMonitoring()
                    } else {
                        appCoordinator.startRecordingFromCurrentConfig()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(actionButtonDisabled)

                if let outputURL = appCoordinator.recorder.lastOutputURL {
                    Button(L10n.tr("legacy.key_123")) {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 10)

                Label(
                    appCoordinator.statusMessage,
                    systemImage: appCoordinator.recorderState.isRecording ? "record.circle.fill" : "record.circle"
                )
                .font(.footnote)
                .foregroundStyle(appCoordinator.recorderState.isRecording ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    private var actionButtonTitle: String {
        if appCoordinator.recorderState.isRecording {
            return L10n.tr("legacy.key_15")
        }
        if appCoordinator.isRecordingArmed {
            return L10n.tr("legacy.key_189")
        }
        return L10n.tr("legacy.key_102")
    }

    private var actionButtonDisabled: Bool {
        if appCoordinator.recorderState.isRecording {
            return appCoordinator.recorderState.isBusy
        }
        return appCoordinator.recorderState.isBusy || !appCoordinator.canStartRecording
    }

    private var microphoneCard: some View {
        card(title: L10n.tr("legacy.key_111"), icon: "mic") {
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

                Button(appCoordinator.audioEngine.isMonitoring ? L10n.tr("legacy.key_17") : L10n.tr("legacy.key_99")) {
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

            if let infoMessage = appCoordinator.audioEngine.infoMessage, !infoMessage.isEmpty {
                Text(L10n.f("fmt.device.status", infoMessage))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isAudioAuthorized: Bool {
        appCoordinator.audioEngine.authorizationStatus == .authorized
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
}
