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

    @State private var customBitrateText = "\(RecordingQualityConfig.defaultConfig.customVideoBitrateMbps)"
    @State private var customBitrateRangeMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroBanner
            recordingControlCard
            recordingQualityCard
            microphoneCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: syncCustomBitrateText)
        .onChange(of: appCoordinator.recordingQualityConfig.customVideoBitrateMbps) { _, _ in
            syncCustomBitrateText()
        }
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
            VStack(alignment: .leading, spacing: 10) {
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

                        Label(
                            appCoordinator.statusMessage,
                            systemImage: appCoordinator.recorderState.isRecording ? "record.circle.fill" : "record.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(appCoordinator.recorderState.isRecording ? Color.red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    } else {
                        Label(
                            appCoordinator.statusMessage,
                            systemImage: appCoordinator.recorderState.isRecording ? "record.circle.fill" : "record.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(appCoordinator.recorderState.isRecording ? Color.red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)
                }

                allRecordingToggleRow
            }
        }
    }

    private var allRecordingToggleRow: some View {
        Toggle(isOn: $appCoordinator.isAllRecordingEnabled) {
            Text("All Recording")
                .font(.caption2)
                .foregroundStyle(
                    appCoordinator.isAllRecordingEnabled
                        ? Color.primary.opacity(0.9)
                        : Color.secondary.opacity(0.5)
                )
        }
        .toggleStyle(.checkbox)
        .disabled(appCoordinator.recorderState.isBusy || appCoordinator.recorderState.isRecording || appCoordinator.isRecordingArmed)
        .controlSize(.small)
    }

    private var recordingQualityCard: some View {
        card(
            title: L10n.tr("recording.quality.title"),
            subtitle: L10n.tr("recording.quality.subtitle"),
            icon: "slider.horizontal.3"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 8) {
                    ForEach(displayedQualityPresets) { preset in
                        qualityPresetButton(for: preset)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Label(resolvedQualitySummary, systemImage: "film")
                    Spacer(minLength: 12)
                    Label(
                        L10n.f("recording.quality.estimate.ten_minutes", formattedEstimatedSize),
                        systemImage: "externaldrive"
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if appCoordinator.recordingQualityConfig.preset == .custom {
                    customQualityControls
                }
            }
        }
    }

    private var customQualityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Grid(alignment: .leading, horizontalSpacing: customControlGroupSpacing, verticalSpacing: 10) {
                GridRow(alignment: .center) {
                    compactControlLabel(L10n.tr("recording.quality.custom.resolution"))

                    compactControlValue(minWidth: customPrimaryControlWidth) {
                        Picker("", selection: customResolutionBinding) {
                            ForEach(RecordingResolutionPreset.allCases) { preset in
                                Text(L10n.tr(preset.titleKey)).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: customResolutionControlWidth, alignment: .leading)
                        .disabled(isQualityEditingDisabled)
                    }

                    compactControlLabel(L10n.tr("recording.quality.custom.fps"))

                    compactControlValue(minWidth: customSecondaryControlWidth) {
                        HStack(alignment: .center, spacing: customInlineHintSpacing) {
                            Picker("", selection: customFPSBinding) {
                                Text("30fps").tag(30)
                                Text("60fps").tag(60)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 140, alignment: .leading)
                            .disabled(isQualityEditingDisabled)

                            if let warningMessage = appCoordinator.recordingQualityWarningMessage {
                                Text(warningMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }

                GridRow(alignment: .center) {
                    compactControlLabel(L10n.tr("recording.quality.custom.codec"))

                    compactControlValue(minWidth: customPrimaryControlWidth) {
                        HStack(alignment: .center, spacing: customInlineHintSpacing) {
                            Picker("", selection: customCodecBinding) {
                                ForEach(RecordingVideoCodec.allCases) { codec in
                                    Text(L10n.tr(codec.titleKey)).tag(codec)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: customCodecControlWidth, alignment: .leading)
                            .disabled(isQualityEditingDisabled)

                            secondarySupportingText(codecHintText)
                        }
                    }

                    compactControlLabel(L10n.tr("recording.quality.custom.bitrate"))

                    compactControlValue(minWidth: customSecondaryControlWidth) {
                        HStack(alignment: .center, spacing: customInlineHintSpacing) {
                            HStack(spacing: 8) {
                                TextField("", text: $customBitrateText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                                    .disabled(isQualityEditingDisabled)
                                    .onChange(of: customBitrateText) { _, _ in
                                        commitCustomBitrateText()
                                    }

                                Text(L10n.tr("recording.quality.unit.mbps"))
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)

                                Stepper(
                                    value: customBitrateValueBinding,
                                    in: RecordingQualityConfig.minimumBitrateMbps...RecordingQualityConfig.maximumBitrateMbps
                                ) {
                                    EmptyView()
                                }
                                .labelsHidden()
                                .disabled(isQualityEditingDisabled)
                            }

                            secondarySupportingText(L10n.tr("recording.quality.custom.bitrate.range_hint"))

                            if let customBitrateRangeMessage {
                                Text(customBitrateRangeMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var isQualityEditingDisabled: Bool {
        appCoordinator.recorderState.isRecording
            || appCoordinator.recorderState.isBusy
            || appCoordinator.isRecordingArmed
    }

    private var resolvedQualitySummary: String {
        let profile = appCoordinator.recordingQualityConfig.resolvedProfile
        return L10n.f(
            "recording.quality.summary",
            L10n.tr(profile.resolution.titleKey),
            profile.fps,
            L10n.tr(profile.codec.titleKey),
            profile.videoBitrateMbps,
            profile.audioBitrateKbps
        )
    }

    private var formattedEstimatedSize: String {
        let sizeMB = appCoordinator.recordingQualityConfig.estimatedTenMinuteSizeMB
        if sizeMB >= 1024 {
            let value = Double(sizeMB) / 1024.0
            return L10n.f("recording.quality.file_size.gb", value)
        }
        return L10n.f("recording.quality.file_size.mb", sizeMB)
    }

    private var codecHintText: String {
        switch appCoordinator.recordingQualityConfig.resolvedProfile.codec {
        case .h264:
            return L10n.tr("recording.quality.codec.h264.hint")
        case .hevc:
            return L10n.tr("recording.quality.codec.hevc.hint")
        }
    }

    private var customResolutionBinding: Binding<RecordingResolutionPreset> {
        Binding(
            get: { appCoordinator.recordingQualityConfig.customResolution },
            set: { newValue in
                updateRecordingQualityConfig { $0.customResolution = newValue }
            }
        )
    }

    private var customFPSBinding: Binding<Int> {
        Binding(
            get: { appCoordinator.recordingQualityConfig.customFPS },
            set: { newValue in
                updateRecordingQualityConfig { $0.customFPS = newValue }
            }
        )
    }

    private var customCodecBinding: Binding<RecordingVideoCodec> {
        Binding(
            get: { appCoordinator.recordingQualityConfig.customCodec },
            set: { newValue in
                updateRecordingQualityConfig { $0.customCodec = newValue }
            }
        )
    }

    private var customBitrateValueBinding: Binding<Int> {
        Binding(
            get: { appCoordinator.recordingQualityConfig.customVideoBitrateMbps },
            set: { newValue in
                customBitrateRangeMessage = nil
                updateRecordingQualityConfig { $0.customVideoBitrateMbps = newValue }
            }
        )
    }

    private var displayedQualityPresets: [RecordingQualityPreset] {
        [.balanced, .small, .highQuality, .proEditing, .custom]
    }

    private var customControlLabelWidth: CGFloat { 84 }

    private var customControlRowSpacing: CGFloat { 8 }

    private var customControlGroupSpacing: CGFloat { 16 }

    private var customInlineHintSpacing: CGFloat { 6 }

    private var customPrimaryControlWidth: CGFloat { 320 }

    private var customSecondaryControlWidth: CGFloat { 220 }

    private var customResolutionControlWidth: CGFloat { 320 }

    private var customCodecControlWidth: CGFloat { 220 }

    @ViewBuilder
    private func card<Content: View>(
        title: String,
        subtitle: String? = nil,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))
                Text(title)
                    .font(.headline)

                if let subtitle, !subtitle.isEmpty {
                    secondarySubtitleText(subtitle)
                }

                Spacer(minLength: 0)
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
    private func secondarySubtitleText(_ text: String, lineLimit: Int = 1) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func secondarySupportingText(_ text: String, lineLimit: Int = 1) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    private func compactControlLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(width: customControlLabelWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func compactControlValue<Content: View>(
        minWidth: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
            .gridCellAnchor(.leading)
    }

    private func qualityPresetButton(for preset: RecordingQualityPreset) -> some View {
        Button {
            customBitrateRangeMessage = nil
            updateRecordingQualityConfig { $0.preset = preset }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: appCoordinator.recordingQualityConfig.preset == preset ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appCoordinator.recordingQualityConfig.preset == preset ? Color.accentColor : .secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.tr(preset.titleKey))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)

                    secondarySubtitleText(L10n.tr(preset.descriptionKey))
                }

                Spacer(minLength: 10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appCoordinator.recordingQualityConfig.preset == preset ? Color.accentColor.opacity(0.08) : Color.black.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        appCoordinator.recordingQualityConfig.preset == preset ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isQualityEditingDisabled)
    }

    private func updateRecordingQualityConfig(_ mutate: (inout RecordingQualityConfig) -> Void) {
        var next = appCoordinator.recordingQualityConfig
        mutate(&next)
        appCoordinator.recordingQualityConfig = next.normalized()
    }

    private func syncCustomBitrateText() {
        let nextValue = "\(appCoordinator.recordingQualityConfig.customVideoBitrateMbps)"
        if customBitrateText != nextValue {
            customBitrateText = nextValue
        }
    }

    private func commitCustomBitrateText() {
        let digitsOnly = customBitrateText.filter(\.isNumber)
        if digitsOnly != customBitrateText {
            customBitrateText = digitsOnly
        }
        guard let rawValue = Int(digitsOnly), !digitsOnly.isEmpty else {
            customBitrateRangeMessage = nil
            return
        }

        if rawValue < RecordingQualityConfig.minimumBitrateMbps {
            customBitrateRangeMessage = L10n.tr("recording.quality.warning.min")
        } else if rawValue > RecordingQualityConfig.maximumBitrateMbps {
            customBitrateRangeMessage = L10n.tr("recording.quality.warning.max")
        } else {
            customBitrateRangeMessage = nil
        }

        updateRecordingQualityConfig { $0.customVideoBitrateMbps = rawValue }
    }
}
