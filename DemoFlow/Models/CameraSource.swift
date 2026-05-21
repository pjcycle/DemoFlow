//
//  CameraSource.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/29.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated struct CameraSource: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let modelID: String
    let isBuiltIn: Bool
    let isContinuity: Bool
    let isAvailable: Bool

    var badgeText: String {
        var tags: [String] = []
        if isBuiltIn {
            tags.append("Built-in")
        }
        if isContinuity {
            tags.append("Continuity")
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
        isBuiltIn = device.deviceType == .builtInWideAngleCamera
            || lowered.contains("facetime")
            || lowered.contains("built-in")
            || lowered.contains("internal")
        isContinuity = device.isContinuityCamera
            || lowered.contains("continuity")
            || lowered.contains("iphone")
    }

    init(
        id: String,
        name: String,
        manufacturer: String,
        modelID: String,
        isBuiltIn: Bool,
        isContinuity: Bool,
        isAvailable: Bool
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.modelID = modelID
        self.isBuiltIn = isBuiltIn
        self.isContinuity = isContinuity
        self.isAvailable = isAvailable
    }
}
