//
//  ScreenDrawingSettingsView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/6.
//

import SwiftUI

struct ScreenDrawingSettingsView: View {
    @ObservedObject var appCoordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            actionCard
            shortcutsCard
            strokeCard
            captureCard
            dismissalCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.9), Color.green.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("section.screenDrawing.title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("section.screenDrawing.subtitle"))
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
                colors: [Color(red: 0.16, green: 0.58, blue: 0.54), Color(red: 0.18, green: 0.36, blue: 0.48)],
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
                .fill(appCoordinator.isDrawOverlayVisible ? .green : .white.opacity(0.85))
                .frame(width: 8, height: 8)
            Text(appCoordinator.drawStatusMessage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24))
        .clipShape(Capsule())
    }

    private var actionCard: some View {
        card(title: topActionTitle, icon: "sparkles") {
            HStack(spacing: 12) {
                Button(topActionTitle) {
                    if appCoordinator.isDrawOverlayVisible {
                        appCoordinator.hideScreenDrawOverlay()
                    } else {
                        appCoordinator.showScreenDrawOverlay()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.tr("legacy.c_2")) {
                    appCoordinator.clearScreenDrawCanvas()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 8)

                Label(
                    appCoordinator.drawStatusMessage,
                    systemImage: appCoordinator.isDrawOverlayVisible ? "pencil.and.scribble" : "pencil.slash"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    private var shortcutsCard: some View {
        card(title: L10n.tr("legacy.key_116"), icon: "keyboard") {
            Group {
                Text(L10n.tr("legacy.key_225"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("legacy.k_1_5_1_2_3_4_5"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Group {
                Text(L10n.tr("legacy.key_81"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("legacy.k_1_6"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Group {
                Text(L10n.tr("legacy.key_178"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("legacy.x"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("legacy.a"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Group {
                Text(L10n.tr("draw.undo.title"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("draw.undo.shortcut"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Label(
                appCoordinator.isDrawGlobalHotkeysEnabled
                    ? L10n.tr("legacy.demoflow_3")
                    : L10n.tr("legacy.demoflow_4"),
                systemImage: appCoordinator.isDrawGlobalHotkeysEnabled ? "globe" : "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var strokeCard: some View {
        card(title: L10n.tr("legacy.key_188"), icon: "scribble.variable") {
            HStack(spacing: 12) {
                Text(L10n.tr("legacy.key_121"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(appCoordinator.drawHandDrawnIntensity) },
                        set: { appCoordinator.setDrawHandDrawnIntensity(CGFloat($0)) }
                    ),
                    in: 0 ... 1
                )
                Text("\(Int(appCoordinator.drawHandDrawnIntensity * 100))%")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
            }

            Picker(
                L10n.tr("legacy.key_48"),
                selection: Binding(
                    get: { appCoordinator.drawMarkStyle },
                    set: { appCoordinator.setDrawMarkStyle($0) }
                )
            ) {
                ForEach(ScreenDrawMarkStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var captureCard: some View {
        card(title: L10n.tr("draw.capture.title"), icon: "camera.viewfinder") {
            Toggle(L10n.tr("draw.capture.toggle"), isOn: Binding(
                get: { appCoordinator.isDrawAutoCaptureOnCloseEnabled },
                set: { appCoordinator.isDrawAutoCaptureOnCloseEnabled = $0 }
            ))

            Text(L10n.tr("draw.capture.hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(L10n.tr("draw.capture.open_dir")) {
                appCoordinator.openScreenDrawAutoCaptureDirectory()
            }
            .buttonStyle(.bordered)
        }
    }

    private var dismissalCard: some View {
        card(title: L10n.tr("draw.dismiss.title"), icon: "sparkles.rectangle.stack") {
            Text(L10n.tr("draw.dismiss.subtitle"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker(
                L10n.tr("draw.dismiss.mode.label"),
                selection: Binding(
                    get: { appCoordinator.drawDismissalAnimationMode },
                    set: { appCoordinator.drawDismissalAnimationMode = $0 }
                )
            ) {
                ForEach(DrawDismissalAnimationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if appCoordinator.drawDismissalAnimationMode == .fixed {
                Picker(
                    L10n.tr("draw.dismiss.style.label"),
                    selection: Binding(
                        get: { appCoordinator.drawDismissalAnimationFixedStyle },
                        set: { appCoordinator.drawDismissalAnimationFixedStyle = $0 }
                    )
                ) {
                    ForEach(DrawDismissalAnimationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            Text(L10n.tr("draw.dismiss.hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var topActionTitle: String {
        appCoordinator.isDrawOverlayVisible ? L10n.tr("legacy.key_148") : L10n.tr("legacy.key_101")
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
}
