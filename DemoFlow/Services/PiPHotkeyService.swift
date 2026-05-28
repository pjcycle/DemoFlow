//
//  PiPHotkeyService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/8.
//

import AppKit
import Carbon
import Foundation

enum PiPHotkeyAction {
    case togglePreview
}

@MainActor
final class PiPHotkeyService {
    var onAction: ((PiPHotkeyAction) -> Void)?
    var shouldHandleAction: ((PiPHotkeyAction) -> Bool)?
    var onRegistrationStatusChanged: ((Bool, String) -> Void)?

    private let globalService = GlobalHotkeyService(
        signature: PiPHotkeyConstants.signature,
        descriptors: PiPHotkeyConstants.descriptors.map { descriptor in
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
                let descriptor = PiPHotkeyConstants.descriptors.first(where: { $0.id == id })
            else { return }
            self.onAction?(descriptor.action)
        }

        globalService.shouldHandleID = { [weak self] id in
            guard
                let self,
                let descriptor = PiPHotkeyConstants.descriptors.first(where: { $0.id == id })
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

private enum PiPHotkeyConstants {
    static let signature: OSType = 0x5049504B // 'PIPK'
    static let descriptors: [HotkeyDescriptor] = [
        HotkeyDescriptor(
            id: 1,
            keyCode: Int16(kVK_ANSI_P),
            modifiers: UInt32(cmdKey | optionKey),
            action: .togglePreview
        ),
        HotkeyDescriptor(
            id: 2,
            keyCode: Int16(kVK_ANSI_P),
            modifiers: UInt32(cmdKey | controlKey),
            action: .togglePreview
        )
    ]
}

private struct HotkeyDescriptor {
    let id: Int
    let keyCode: Int16
    let modifiers: UInt32
    let action: PiPHotkeyAction
}
