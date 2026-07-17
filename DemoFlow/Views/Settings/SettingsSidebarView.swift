//
//  SettingsSidebarView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit
import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selectedSection: SettingsSection
    @Binding var isCollapsed: Bool
    @ObservedObject var subscriptionViewModel: SubscriptionViewModel
    var onSectionSelected: ((SettingsSection) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            mainNavList
            Spacer(minLength: 0)
            bottomSettingsEntry
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: isCollapsed ? 24 : 28, height: isCollapsed ? 24 : 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            if !isCollapsed {
                brandTitle
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "sidebar.leading" : "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? L10n.tr("sidebar.expand") : L10n.tr("sidebar.collapse"))
        }
    }

    @ViewBuilder
    private var brandTitle: some View {
        if let badgeText = subscriptionViewModel.membershipBadgeText {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.88, green: 0.63, blue: 0.14))

                Text(badgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    )
            }
        } else {
            Text(productDisplayName)
                .font(.headline)
                .lineLimit(1)
        }
    }

    private var applicationIconImage: NSImage {
        NSApp.applicationIconImage
    }

    private var productDisplayName: String {
        let info = Bundle.main.infoDictionary
        if let displayName = (info?["CFBundleDisplayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let bundleName = (info?["CFBundleName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleName.isEmpty {
            return bundleName
        }
        return "DemoFlow"
    }

    private var mainNavList: some View {
        VStack(spacing: 6) {
            ForEach(orderedMainSections) { section in
                sidebarRow(section: section)
            }
        }
    }

    private var orderedMainSections: [SettingsSection] {
        [
            .recording,
            .pipCamera,
            .screenDrawing,
            .videoCutting,
            .audioExtract,
            .subDub
        ]
    }

    private var bottomSettingsEntry: some View {
        VStack(spacing: 6) {
            Divider()
            sidebarRow(section: .appSettings)
        }
    }

    private func sidebarRow(section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
            onSectionSelected?(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .white : .primary)

                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                        Text(section.sidebarSubtitle)
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : .secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(section.title)
    }
}
