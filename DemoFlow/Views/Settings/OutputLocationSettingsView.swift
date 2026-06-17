//
//  OutputLocationSettingsView.swift
//  DemoFlow
//
//  2026-06-17 新增：苹果审核 Guideline 2.4.5(i) 整改。
//  把录屏 / PiP 录像 / 屏幕画图自动截图 / 音频提取的输出位置改为
//  由用户主动选择（NSOpenPanel 选目录 / NSSavePanel 选文件）。
//

import AppKit
import SwiftUI

struct OutputLocationSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject var audioExtractViewModel: AudioExtractViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                L10n.tr("output.location.section_title"),
                subtitle: L10n.tr("output.location.section_subtitle")
            )

            recordingsCard
            audioExtractCard
        }
    }

    // MARK: - 录屏 / PiP / 屏幕画图自动截图 共用

    private var recordingsCard: some View {
        card(title: L10n.tr("output.location.recordings.title"), icon: "folder.fill.badge.gearshape") {
            HStack(spacing: 10) {
                Text(recordingsPathText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(recordingsConfigured ? Color.primary : .secondary)
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

                Button(L10n.tr("output.location.recordings.choose")) {
                    appCoordinator.requestPickRecordingsDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("output.location.recordings.open")) {
                    appCoordinator.openRecordingOutputDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(!recordingsConfigured)

                Button(L10n.tr("output.location.recordings.reset")) {
                    appCoordinator.clearRecordingsDirectorySelection()
                }
                .buttonStyle(.bordered)
                .disabled(!recordingsConfigured)
            }
        }
    }

    // MARK: - 音频提取

    private var audioExtractCard: some View {
        card(title: L10n.tr("output.location.audio.title"), icon: "music.note.list") {
            HStack(spacing: 10) {
                Text(audioExtractPathText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(audioExtractConfigured ? Color.primary : .secondary)
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

                Button(L10n.tr("output.location.audio.choose")) {
                    audioExtractViewModel.pickOutputDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("output.location.audio.open")) {
                    audioExtractViewModel.openOutputDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(!audioExtractConfigured)
            }
        }
    }

    // MARK: - Helpers

    private var recordingsConfigured: Bool {
        appCoordinator.isRecordingsOutputDirectoryConfigured
    }

    private var recordingsPathText: String {
        if let path = appCoordinator.recordingsOutputDirectoryPath {
            return path
        }
        return L10n.tr("output.location.recordings.empty")
    }

    private var audioExtractConfigured: Bool {
        audioExtractViewModel.outputMP3URL != nil
    }

    private var audioExtractPathText: String {
        if let path = audioExtractViewModel.outputMP3URL?.path {
            return path
        }
        return L10n.tr("output.location.audio.empty")
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
    private func card<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
