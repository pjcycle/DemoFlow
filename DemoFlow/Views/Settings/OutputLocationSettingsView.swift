//
//  OutputLocationSettingsView.swift
//  DemoFlow
//
//  2026-06-17 新增：苹果审核 Guideline 2.4.5(i) 整改。
//  2026-07-08 调整：设置页收敛为单模块，并增加音频工具总输出目录。
//

import AppKit
import SwiftUI

struct OutputLocationSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject var audioExtractViewModel: AudioExtractViewModel

    var body: some View {
        settingsCard
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))

                Text(L10n.tr("section.settings.title"))
                    .font(.headline)
            }

            languageSection

            Divider()

            recordingsSection

            Divider()

            audioSection
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

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(
                L10n.tr("language.settings.card.title"),
                subtitle: L10n.tr("language.settings.card.description")
            )

            HStack(spacing: 14) {
                Picker(
                    L10n.tr("language.settings.picker.label"),
                    selection: Binding(
                        get: { appCoordinator.languageOption },
                        set: { appCoordinator.languageOption = $0 }
                    )
                ) {
                    Text(L10n.tr(L10n.optionAuto)).tag(AppLanguageOption.auto)
                    Text(L10n.tr(L10n.optionChinese)).tag(AppLanguageOption.zhHans)
                    Text(L10n.tr(L10n.optionEnglish)).tag(AppLanguageOption.en)
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Text(L10n.tr("language.settings.card.note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(L10n.tr("privacy.notice.view")) {
                    appCoordinator.openPrivacyPolicyURL()
                }
                .buttonStyle(.bordered)
            }

            if let errorMessage = appCoordinator.privacyPolicyOpenErrorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(
                L10n.tr("output.location.recordings.title"),
                subtitle: L10n.tr("output.location.recordings.note")
            )

            HStack(spacing: 10) {
                pathField(recordingsPathText, configured: recordingsConfigured)

                Button(L10n.tr("output.location.recordings.choose")) {
                    appCoordinator.requestPickRecordingsDirectory()
                }
                .buttonStyle(.bordered)
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

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(
                L10n.tr("output.location.audio.title"),
                subtitle: L10n.tr("output.location.audio.note")
            )

            HStack(spacing: 10) {
                pathField(audioExtractPathText, configured: audioExtractConfigured)

                Button(L10n.tr("output.location.audio.choose")) {
                    audioExtractViewModel.pickOutputDirectory()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button(L10n.tr("output.location.audio.open")) {
                    audioExtractViewModel.openOutputDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(!audioExtractConfigured)

                Button(L10n.tr("output.location.recordings.reset")) {
                    audioExtractViewModel.clearOutputDirectorySelection()
                }
                .buttonStyle(.bordered)
                .disabled(!audioExtractConfigured)
            }
        }
    }

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
    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pathField(_ text: String, configured: Bool) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(configured ? Color.primary : .secondary)
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
