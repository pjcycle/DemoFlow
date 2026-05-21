//
//  SettingsSidebarView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selectedSection: SettingsSection
    @Binding var isCollapsed: Bool
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
        HStack {
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("sidebar.header.title"))
                        .font(.headline)
                    Text(L10n.tr("sidebar.header.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            .audioExtract
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
                        Text(section.subtitle)
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
