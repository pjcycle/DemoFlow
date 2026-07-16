//
//  OutputLocationSettingsView.swift
//  DemoFlow
//
//  2026-06-17 新增：苹果审核 Guideline 2.4.5(i) 整改。
//  2026-07-09 调整：设置页收敛为单卡片，并切换到统一 DemoFlow 输出工作区。
//

import AppKit
import SwiftUI

struct OutputLocationSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject var audioExtractViewModel: AudioExtractViewModel

    var body: some View {
        settingsCard
            .sheet(isPresented: privacyPolicySheetBinding) {
                SettingsPrivacyPolicySheet()
            }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            languageRow
            Divider()
            workspaceSection
            Divider()
            actionRow(
                title: L10n.tr("subscription.entry.title"),
                subtitle: L10n.tr("subscription.entry.subtitle"),
                systemImage: "crown.fill"
            ) {
                appCoordinator.openSubscriptionWindow()
            }
            Divider()
            actionRow(
                title: L10n.tr("privacy.notice.view"),
                subtitle: L10n.tr("settings.privacy.subtitle"),
                systemImage: "lock.shield"
            ) {
                appCoordinator.openPrivacyPolicyURL()
            }
            Divider()
            actionRow(
                title: L10n.tr("settings.support.title"),
                subtitle: L10n.tr("settings.support.subtitle"),
                systemImage: "envelope"
            ) {
                appCoordinator.openSupportEmail()
            }
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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))

            Text(L10n.tr("section.settings.title"))
                .font(.headline)
        }
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.48, blue: 0.78))

            Picker(
                "",
                selection: Binding(
                    get: { appCoordinator.languageOption },
                    set: { appCoordinator.languageOption = $0 }
                )
            ) {
                Text(L10n.tr(L10n.optionAuto)).tag(AppLanguageOption.auto)
                Text(L10n.tr(L10n.optionChinese)).tag(AppLanguageOption.zhHans)
                Text(L10n.tr(L10n.optionEnglish)).tag(AppLanguageOption.en)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.23, green: 0.58, blue: 0.35))

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("output.location.workspace.title"))
                        .font(.headline)

                    pathField(workspacePathText, configured: workspaceConfigured)

                    Text(L10n.tr("output.location.workspace.note"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if workspaceConfigured {
                    Button(L10n.tr("output.location.workspace.change")) {
                        if appCoordinator.requestPickRecordingsDirectory() {
                            audioExtractViewModel.syncOutputDirectoryFromPolicy()
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(L10n.tr("output.location.workspace.choose")) {
                        if appCoordinator.requestPickRecordingsDirectory() {
                            audioExtractViewModel.syncOutputDirectoryFromPolicy()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(L10n.tr("output.location.workspace.open")) {
                    appCoordinator.openOutputWorkspaceDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(!workspaceConfigured)

                Button(L10n.tr("output.location.workspace.reset")) {
                    appCoordinator.clearRecordingsDirectorySelection()
                    audioExtractViewModel.syncOutputDirectoryFromPolicy()
                }
                .buttonStyle(.bordered)
                .disabled(!workspaceConfigured)
            }
        }
    }

    private var workspaceConfigured: Bool {
        appCoordinator.isOutputWorkspaceConfigured
    }

    private var workspacePathText: String {
        if let path = appCoordinator.outputWorkspaceRootDirectoryPath {
            return path
        }
        return L10n.tr("output.location.workspace.empty")
    }

    private var privacyPolicySheetBinding: Binding<Bool> {
        Binding(
            get: { appCoordinator.isPrivacyPolicySheetPresented },
            set: { isPresented in
                if !isPresented {
                    appCoordinator.dismissPrivacyPolicySheet()
                }
            }
        )
    }

    @ViewBuilder
    private func actionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.54, green: 0.42, blue: 0.17))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
