//
//  AudioInputSource.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct AudioInputSource: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let modelID: String
    let isContinuity: Bool
    let isAvailable: Bool

    var isBuiltIn: Bool {
        let lowered = name.lowercased()
        return lowered.contains("built-in")
            || lowered.contains("macbook")
            || lowered.contains("mac mini")
            || lowered.contains("imac")
    }

    var badgeText: String {
        var tags: [String] = []
        if isContinuity {
            tags.append("Continuity")
        }
        if isBuiltIn {
            tags.append("Built-in")
        }
        if !isAvailable {
            tags.append("Offline")
        }
        return tags.joined(separator: " · ")
    }

    init(device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
        manufacturer = device.manufacturer
        modelID = device.modelID
        isAvailable = device.isConnected && !device.isSuspended

        let lowered = device.localizedName.lowercased()
        isContinuity = device.isContinuityCamera
            || lowered.contains("iphone")
            || lowered.contains("continuity")
    }
}
