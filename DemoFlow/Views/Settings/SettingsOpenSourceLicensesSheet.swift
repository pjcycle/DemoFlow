//
//  SettingsOpenSourceLicensesSheet.swift
//  DemoFlow
//
//  2026-08-18 新增：设置页内置开源许可致谢弹窗（ffmpeg / ffprobe / whisper-cli）。
//

import AppKit
import SwiftUI

struct SettingsOpenSourceLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        licenseCard(item)
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
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("opensource.licenses.title"))
                    .font(.title3.weight(.semibold))

                Text(L10n.tr("opensource.licenses.sheet.subtitle"))
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

    fileprivate struct LicenseItem {
        let name: String
        let purpose: String
        let license: String
        let url: String
    }

    fileprivate var items: [LicenseItem] {
        L10n.tr("opensource.licenses.body")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { block in
                var name = ""
                var purpose = ""
                var license = ""
                var url = ""
                for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let separator = trimmed.firstIndex(of: "=") else { continue }
                    let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(trimmed[trimmed.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    switch key {
                    case "name": name = value
                    case "purpose": purpose = value
                    case "license": license = value
                    case "url": url = value
                    default: break
                    }
                }
                guard !name.isEmpty else { return nil }
                return LicenseItem(
                    name: name,
                    purpose: purpose,
                    license: license,
                    url: url
                )
            }
    }

    @ViewBuilder
    private func licenseCard(_ item: LicenseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.headline)

            Text(item.purpose)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(item.license)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    )

                Button(item.url) {
                    if let parsed = URL(string: item.url) {
                        NSWorkspace.shared.open(parsed)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}