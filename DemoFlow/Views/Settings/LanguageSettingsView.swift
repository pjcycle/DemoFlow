//
//  LanguageSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import AppKit
import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(L10n.tr("language.settings.header.title"), subtitle: L10n.tr("language.settings.header.subtitle"))

            card {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("language.settings.card.title"))
                            .font(.headline)
                        Text(L10n.tr("language.settings.card.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

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
                }

                Text(L10n.tr("language.settings.card.note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(L10n.tr("privacy.notice.view")) {
                        appCoordinator.openPrivacyPolicyURL()
                    }
                    .buttonStyle(.bordered)

                    if let errorMessage = appCoordinator.privacyPolicyOpenErrorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
