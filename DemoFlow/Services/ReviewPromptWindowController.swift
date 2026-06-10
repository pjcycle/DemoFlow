//
//  ReviewPromptWindowController.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/6/10.
//

import AppKit
import Foundation
import SwiftUI

enum ReviewPromptSource: String {
    case recording
    case videoExport

    var initialMilestones: [Int] {
        switch self {
        case .recording:
            return [3, 5, 15, 30, 50, 100]
        case .videoExport:
            return [5, 10, 20, 30, 50, 100]
        }
    }

    private var defaultsPrefix: String {
        "demoflow.review_prompt.\(rawValue)"
    }

    var countDefaultsKey: String { "\(defaultsPrefix).count" }
    var lastPromptedMilestoneDefaultsKey: String { "\(defaultsPrefix).last_prompted_milestone" }
    var lastFiveStarCountDefaultsKey: String { "\(defaultsPrefix).last_five_star_count" }
}

struct ReviewPromptCounterState {
    var count: Int
    var lastPromptedMilestone: Int
    var lastFiveStarCount: Int
}

struct ReviewPromptPayload: Equatable {
    let source: ReviewPromptSource
    let count: Int
    let promptedMilestone: Int
}

@MainActor
final class ReviewPromptWindowController: NSObject {
    private let panelSize = CGSize(width: 440, height: 326)
    private var panel: ReviewPromptPanel?
    private var hostingView: NSHostingView<ReviewPromptCardView>?

    var onLater: (() -> Void)?
    var onStarSelected: ((Int) -> Void)?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(payload: ReviewPromptPayload, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        applyContent(payload: payload, to: panel)

        if let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first {
            panel.setFrame(frame(for: panel, on: targetScreen), display: true)
        } else {
            panel.center()
        }

        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> ReviewPromptPanel {
        let panel = ReviewPromptPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.identifier = NSUserInterfaceItemIdentifier("review-prompt-window")
        panel.onCancel = { [weak self] in
            self?.onLater?()
        }
        return panel
    }

    private func applyContent(payload: ReviewPromptPayload, to panel: ReviewPromptPanel) {
        let rootView = ReviewPromptCardView(
            appIcon: NSApp.applicationIconImage,
            onLater: { [weak self] in
                self?.onLater?()
            },
            onStarSelected: { [weak self] star in
                self?.onStarSelected?(star)
            }
        )

        if let hostingView {
            hostingView.rootView = rootView
            hostingView.frame = NSRect(origin: .zero, size: panelSize)
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.frame = NSRect(origin: .zero, size: panelSize)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
    }

    private func frame(for panel: NSPanel, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        return CGRect(
            x: visible.midX - (size.width / 2.0),
            y: visible.midY - (size.height / 2.0),
            width: size.width,
            height: size.height
        )
    }
}

private final class ReviewPromptPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct ReviewPromptCardView: View {
    let appIcon: NSImage
    let onLater: () -> Void
    let onStarSelected: (Int) -> Void

    @State private var hoveredStar: Int = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor),
                            Color(nsColor: .windowBackgroundColor)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("review.prompt.title"))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(L10n.tr("review.prompt.message"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                    .padding(.top, 20)
                    .padding(.bottom, 18)

                HStack(spacing: 16) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            onStarSelected(star)
                        } label: {
                            Image(systemName: hoveredStar >= star ? "star.fill" : "star")
                                .font(.system(size: 27, weight: .regular))
                                .foregroundStyle(hoveredStar >= star ? Color.accentColor : Color.secondary.opacity(0.8))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            if isHovering {
                                hoveredStar = star
                            } else if hoveredStar == star {
                                hoveredStar = 0
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 22)

                Button(L10n.tr("review.prompt.later")) {
                    onLater()
                }
                .buttonStyle(.plain)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
            }
            .padding(24)
        }
        .frame(width: 440, height: 326)
    }
}
