//
//  ScreenDrawHotkeyService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import AppKit
import Carbon
import Foundation

enum ScreenDrawHotkeyAction {
    case selectColor(DrawColorPreset)
    case selectTool(ScreenDrawTool)
    case toggleOverlay
    case toggleCanvasPassthrough
    case undo
}

@MainActor
final class ScreenDrawHotkeyService {
    var onAction: ((ScreenDrawHotkeyAction) -> Void)?
    var shouldHandleAction: ((ScreenDrawHotkeyAction) -> Bool)?
    var onRegistrationStatusChanged: ((Bool, String) -> Void)?

    private let globalService = GlobalHotkeyService(
        signature: ScreenDrawHotkeyConstants.signature,
        descriptors: ScreenDrawHotkeyConstants.descriptors.map { descriptor in
            GlobalHotkeyDescriptor(
                id: descriptor.id,
                keyCode: descriptor.keyCode,
                modifiers: descriptor.modifiers,
                registerGlobally: descriptor.registerGlobally
            )
        }
    )

    func start() -> Bool {
        globalService.onHotkeyID = { [weak self] id in
            guard
                let self,
                let descriptor = ScreenDrawHotkeyConstants.descriptors.first(where: { $0.id == id })
            else { return }
            self.onAction?(descriptor.action)
        }

        globalService.shouldHandleID = { [weak self] id in
            guard
                let self,
                let descriptor = ScreenDrawHotkeyConstants.descriptors.first(where: { $0.id == id })
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

private enum ScreenDrawHotkeyConstants {
    static let signature: OSType = 0x53445257 // 'SDRW'
    static let descriptors: [HotkeyDescriptor] = [
        HotkeyDescriptor(id: 1, keyCode: Int16(kVK_ANSI_1), modifiers: UInt32(controlKey | optionKey), action: .selectColor(.one)),
        HotkeyDescriptor(id: 2, keyCode: Int16(kVK_ANSI_2), modifiers: UInt32(controlKey | optionKey), action: .selectColor(.two)),
        HotkeyDescriptor(id: 3, keyCode: Int16(kVK_ANSI_3), modifiers: UInt32(controlKey | optionKey), action: .selectColor(.three)),
        HotkeyDescriptor(id: 4, keyCode: Int16(kVK_ANSI_4), modifiers: UInt32(controlKey | optionKey), action: .selectColor(.four)),
        HotkeyDescriptor(id: 5, keyCode: Int16(kVK_ANSI_5), modifiers: UInt32(controlKey | optionKey), action: .selectColor(.five)),
        HotkeyDescriptor(id: 6, keyCode: Int16(kVK_ANSI_1), modifiers: UInt32(cmdKey | optionKey), action: .selectTool(.line)),
        HotkeyDescriptor(id: 7, keyCode: Int16(kVK_ANSI_2), modifiers: UInt32(cmdKey | optionKey), action: .selectTool(.arrow)),
        HotkeyDescriptor(id: 8, keyCode: Int16(kVK_ANSI_3), modifiers: UInt32(cmdKey | optionKey), action: .selectTool(.rectangle)),
        HotkeyDescriptor(id: 9, keyCode: Int16(kVK_ANSI_4), modifiers: UInt32(cmdKey | optionKey), action: .selectTool(.ellipse)),
        HotkeyDescriptor(id: 10, keyCode: Int16(kVK_ANSI_5), modifiers: UInt32(cmdKey | optionKey), action: .selectTool(.cross)),
        HotkeyDescriptor(id: 11, keyCode: Int16(kVK_ANSI_6), modifiers: UInt32(cmdKey | optionKey), action: .selectTool(.check)),
        HotkeyDescriptor(id: 12, keyCode: Int16(kVK_ANSI_S), modifiers: UInt32(cmdKey | controlKey), action: .toggleOverlay),
        HotkeyDescriptor(id: 13, keyCode: Int16(kVK_ANSI_X), modifiers: UInt32(cmdKey | controlKey), action: .toggleCanvasPassthrough),
        HotkeyDescriptor(id: 14, keyCode: Int16(kVK_ANSI_Z), modifiers: UInt32(cmdKey), action: .undo, registerGlobally: false)
    ]
}

private struct HotkeyDescriptor {
    let id: Int
    let keyCode: Int16
    let modifiers: UInt32
    let action: ScreenDrawHotkeyAction
    let registerGlobally: Bool

    init(
        id: Int,
        keyCode: Int16,
        modifiers: UInt32,
        action: ScreenDrawHotkeyAction,
        registerGlobally: Bool = true
    ) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
        self.registerGlobally = registerGlobally
    }
}
