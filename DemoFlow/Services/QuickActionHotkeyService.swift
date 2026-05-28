//
//  QuickActionHotkeyService.swift
//  DemoFlow
//
//  Created by OpenAI Codex on 2026/5/25.
//

import AppKit
import Carbon
import Foundation

enum QuickActionHotkeyAction {
    case toggleRecording
    case togglePiPRecording
}

@MainActor
final class QuickActionHotkeyService {
    var onAction: ((QuickActionHotkeyAction) -> Void)?
    var shouldHandleAction: ((QuickActionHotkeyAction) -> Bool)?
    var onRegistrationStatusChanged: ((Bool, String) -> Void)?

    private let globalService = GlobalHotkeyService(
        signature: QuickActionHotkeyConstants.signature,
        descriptors: QuickActionHotkeyConstants.descriptors.map { descriptor in
            GlobalHotkeyDescriptor(
                id: descriptor.id,
                keyCode: descriptor.keyCode,
                modifiers: descriptor.modifiers
            )
        }
    )

    func start() -> Bool {
        globalService.onHotkeyID = { [weak self] id in
            guard
                let self,
                let descriptor = QuickActionHotkeyConstants.descriptors.first(where: { $0.id == id })
            else { return }
            self.onAction?(descriptor.action)
        }

        globalService.shouldHandleID = { [weak self] id in
            guard
                let self,
                let descriptor = QuickActionHotkeyConstants.descriptors.first(where: { $0.id == id })
            else { return false }
            return self.shouldHandleAction?(descriptor.action) ?? true
        }

        globalService.onRegistrationStatusChanged = { [weak self] enabled, message in
            self?.onRegistrationStatusChanged?(enabled, message)
        }

        return globalService.start()
    }

    func stop() {
        globalService.stop()
    }

    func handleEvent(_ event: NSEvent) {
        globalService.handleEvent(event)
    }
}

private enum QuickActionHotkeyConstants {
    static let signature: OSType = 0x5243484B // 'RCHK'
    static let descriptors: [HotkeyDescriptor] = [
        HotkeyDescriptor(
            id: 1,
            keyCode: Int16(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            action: .toggleRecording
        ),
        HotkeyDescriptor(
            id: 2,
            keyCode: Int16(kVK_ANSI_P),
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            action: .togglePiPRecording
        )
    ]
}

private struct HotkeyDescriptor {
    let id: Int
    let keyCode: Int16
    let modifiers: UInt32
    let action: QuickActionHotkeyAction
}
