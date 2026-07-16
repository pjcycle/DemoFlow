//
//  SubscriptionWindowController.swift
//  DemoFlow
//
//  2026-07-11 新增：订阅窗口式承载器，替代 teaser/paywall 双 sheet。
//

import AppKit
import SwiftUI

@MainActor
final class SubscriptionWindowController: NSObject, NSWindowDelegate {
    private let windowSize = SubscriptionWindowLayout.windowSize
    private var window: NSWindow?
    private var hostingController: NSHostingController<SubscriptionWindowView>?
    private var currentViewModel: SubscriptionViewModel?
    private var onClose: (() -> Void)?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(
        subscriptionViewModel: SubscriptionViewModel,
        onClose: @escaping () -> Void,
        on screen: NSScreen?
    ) {
        currentViewModel = subscriptionViewModel
        self.onClose = onClose

        let window = window ?? makeWindow()
        let rootView = SubscriptionWindowView(
            subscriptionViewModel: subscriptionViewModel,
            onClose: { [weak self] in
                self?.requestClose()
            }
        )
        applyContent(rootView, to: window)
        window.setContentSize(windowSize)
        positionWindowAtCenter(window, on: screen)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        positionWindowAtCenter(window, on: screen)
        self.window = window
    }

    func hide() {
        window?.close()
        onClose = nil
        currentViewModel = nil
    }

    private func requestClose() {
        guard currentViewModel?.isPurchasing != true else { return }
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.title = L10n.tr("subscription.paywall.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier("subscription-window")
        return window
    }

    private func applyContent(_ rootView: SubscriptionWindowView, to window: NSWindow) {
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            window.contentViewController = hostingController
            self.hostingController = hostingController
        }
    }

    private func positionWindowAtCenter(_ window: NSWindow, on preferredScreen: NSScreen?) {
        guard let screen = preferredScreen ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = CGPoint(
            x: round(visible.midX - (size.width / 2.0)),
            y: round(visible.midY - (size.height / 2.0))
        )
        window.setFrameOrigin(origin)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        currentViewModel?.isPurchasing != true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === self.window {
            self.window = nil
            hostingController = nil
            currentViewModel = nil
            onClose = nil
        }
    }
}
