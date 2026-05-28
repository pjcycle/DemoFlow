//
//  AudioExtractSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/12.
//

import SwiftUI

struct AudioExtractSettingsView: View {
    @ObservedObject var viewModel: AudioExtractViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            sourceCard
            outputCard
            runCard
            logsCard
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isExtracting)
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
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(viewModel.statusMessage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24))
        .clipShape(Capsule())
    }

    private var sourceCard: some View {
        card(title: L10n.tr("audio.extract.label.source_type"), icon: "link.badge.plus") {
            VStack(alignment: .leading, spacing: 6) {
                Picker(L10n.tr("audio.extract.label.source_type"), selection: $viewModel.sourceType) {
                    ForEach(AudioExtractSourceType.allCases) { type in
                        Text(L10n.tr(type.titleKey)).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                sourceSwitchPanel

                HStack(spacing: 12) {
                    Picker(L10n.tr("audio.extract.label.quality"), selection: $viewModel.quality) {
                        ForEach(AudioExtractQualityPreset.allCases) { preset in
                            Text(L10n.tr(preset.titleKey)).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Divider()
                        .frame(height: 16)

                    Toggle(L10n.tr("audio.extract.label.install_deps"), isOn: $viewModel.installDependencies)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private var sourceSwitchPanel: some View {
        Group {
            if viewModel.sourceType == .localFile {
                localSourcePanel
            } else {
                urlSourcePanel
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        .clipped()
    }

    private var localSourcePanel: some View {
        HStack(spacing: 10) {
            logLikeField(viewModel.localFilePathText)
            Button(L10n.tr("audio.extract.action.select_file")) {
                viewModel.pickLocalFile()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var urlSourcePanel: some View {
        TextField(L10n.tr("audio.extract.placeholder.url"), text: $viewModel.sourceURLString)
            .textFieldStyle(.roundedBorder)
    }

    private var outputCard: some View {
        card(title: L10n.tr("audio.extract.label.output_dir"), icon: "folder.badge.gearshape") {
            HStack(spacing: 10) {
                logLikeField(viewModel.outputRootPathText)
                Button(L10n.tr("audio.extract.action.select_output")) {
                    viewModel.pickOutputDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("audio.extract.action.open_output")) {
                    viewModel.openOutputDirectory()
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("audio.extract.action.reveal_latest")) {
                    viewModel.revealLatestMP3()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var runCard: some View {
        card(title: L10n.tr("audio.extract.action.start"), icon: "play.circle.fill") {
            HStack(spacing: 10) {
                Button(L10n.tr("audio.extract.action.start")) {
                    viewModel.startExtraction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canStart)

                Button(L10n.tr("audio.extract.action.stop")) {
                    viewModel.stopExtraction()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canStop)

                Spacer(minLength: 8)

                Text(viewModel.statusMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))
                Text(L10n.tr("audio.extract.label.logs"))
                    .font(.headline)
                Spacer(minLength: 8)
                Button(L10n.tr("audio.extract.action.clear_logs")) {
                    viewModel.clearLogs()
                }
                .buttonStyle(.bordered)
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

    private var logBodyText: String {
        if viewModel.logs.isEmpty {
            return "[status] \(L10n.tr("audio.extract.status.idle"))"
        }
        return viewModel.logs.joined(separator: "\n")
    }

    private var statusColor: Color {
        if viewModel.isExtracting { return .yellow }
        if viewModel.latestMP3URL != nil { return .green }
        return .white.opacity(0.85)
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
