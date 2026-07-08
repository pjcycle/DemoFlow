//
//  AudioExtractSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/12.
//

import SwiftUI

struct AudioExtractSettingsView: View {
    @ObservedObject var viewModel: AudioToolViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            tabBar
            currentTabView
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.currentStatusText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.9), Color.red.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("section.audioExtract.title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("section.audioExtract.subtitle"))
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
                colors: [Color(red: 0.90, green: 0.39, blue: 0.18), Color(red: 0.16, green: 0.45, blue: 0.62)],
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
                .fill(viewModel.currentStatusColor)
                .frame(width: 8, height: 8)
            Text(viewModel.currentStatusText)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24))
        .clipShape(Capsule())
    }

    private var tabBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 22) {
                ForEach(AudioToolTab.allCases) { tab in
                    let isSelected = viewModel.selectedTab == tab
                    Button {
                        viewModel.selectedTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            Text(L10n.tr(tab.titleKey))
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var currentTabView: some View {
        switch viewModel.selectedTab {
        case .extract:
            extractPanel
        case .transcode:
            AudioTranscodeWorkbenchView(viewModel: viewModel.transcodeViewModel)
        case .trim:
            AudioTrimWorkbenchView(viewModel: viewModel.trimViewModel)
        }
    }

    private var extractPanel: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                extractToolbarRow

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Picker(L10n.tr("audio.extract.label.source_type"), selection: $viewModel.extractViewModel.sourceType) {
                            ForEach(AudioExtractSourceType.allCases) { type in
                                Text(L10n.tr(type.titleKey)).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker(L10n.tr("audio.extract.label.quality"), selection: $viewModel.extractViewModel.quality) {
                            ForEach(AudioExtractQualityPreset.allCases) { preset in
                                Text(L10n.tr(preset.titleKey)).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    sourceInputRow
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))

                        Text(L10n.tr("audio.extract.label.logs"))
                            .font(.headline)
                    }

                    ScrollView {
                        Text(logBodyText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(minHeight: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.82))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
            }
        }
    }

    private var extractToolbarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text(L10n.tr("audio.tool.tab.extract"))
                    .font(.headline)

                Button(L10n.tr("audio.extract.action.start")) {
                    viewModel.extractViewModel.startExtraction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.extractViewModel.canStart)

                Button(L10n.tr("audio.extract.action.stop")) {
                    viewModel.extractViewModel.stopExtraction()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.extractViewModel.canStop)

                if viewModel.extractViewModel.outputMP3URL == nil {
                    Button(L10n.tr("audio.extract.action.select_output")) {
                        viewModel.extractViewModel.pickOutputDirectory()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(L10n.tr("audio.extract.action.open_output")) {
                        viewModel.extractViewModel.openOutputDirectory()
                    }
                    .buttonStyle(.bordered)
                }

                Button(L10n.tr("audio.extract.action.reveal_latest")) {
                    viewModel.extractViewModel.revealLatestMP3()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.extractViewModel.latestMP3URL == nil)

                Button(L10n.tr("audio.extract.action.clear_logs")) {
                    viewModel.extractViewModel.clearLogs()
                }
                .buttonStyle(.bordered)

                statusPill(viewModel.extractViewModel.statusMessage)
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    @ViewBuilder
    private var sourceInputRow: some View {
        if viewModel.extractViewModel.sourceType == .localFile {
            HStack(spacing: 10) {
                logLikeField(viewModel.extractViewModel.localFilePathText)

                Button(L10n.tr("audio.extract.action.select_file")) {
                    viewModel.extractViewModel.pickLocalFile()
                }
                .buttonStyle(.bordered)
            }
        } else {
            TextField(L10n.tr("audio.extract.placeholder.url"), text: $viewModel.extractViewModel.sourceURLString)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var logBodyText: String {
        if viewModel.extractViewModel.logs.isEmpty {
            return "[status] \(L10n.tr("audio.extract.status.idle"))"
        }
        return viewModel.extractViewModel.logs.joined(separator: "\n")
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.04)))
    }

    @ViewBuilder
    private func logLikeField(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.07), lineWidth: 1)
            )
    }
}
