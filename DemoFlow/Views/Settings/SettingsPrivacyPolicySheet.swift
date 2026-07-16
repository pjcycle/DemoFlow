//
//  SettingsPrivacyPolicySheet.swift
//  DemoFlow
//
//  2026-07-09 新增：设置页内置隐私协议查看弹窗。
//

import SwiftUI

struct SettingsPrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("privacy.notice.title"))
                    .font(.title3.weight(.semibold))

                Text(L10n.tr("settings.privacy.sheet.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(L10n.tr("settings.sheet.close")) {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var paragraphs: [String] {
        L10n.tr("privacy.policy.body")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
