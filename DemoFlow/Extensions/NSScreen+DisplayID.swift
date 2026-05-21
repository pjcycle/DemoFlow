//
//  NSScreen+DisplayID.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func screen(with displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { $0.displayID == displayID })
    }
}
