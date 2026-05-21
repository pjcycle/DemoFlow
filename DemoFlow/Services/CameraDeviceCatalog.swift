//
//  CameraDeviceCatalog.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/1.
//

@preconcurrency import AVFoundation
import Foundation

final class CameraDeviceCatalog {
    static let shared = CameraDeviceCatalog()

    private init() {}

    func fetchVideoSnapshot(includeOffline: Bool = true) -> DeviceSnapshot<CameraSource> {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .continuityCamera,
                .external,
                .deskViewCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        let discoveryDevices = discoverySession.devices
        var devices = discoveryDevices
        var usedLegacyFallback = false
        var includedSystemDefault = false

        if devices.isEmpty {
            usedLegacyFallback = true
        }

        if let preferred = AVCaptureDevice.default(for: .video),
           !devices.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            devices.append(preferred)
            includedSystemDefault = true
        }

        let normalized = normalize(devices, includeOffline: includeOffline)
        return DeviceSnapshot(
            devices: normalized.map(CameraSource.init(device:)),
            discoveryCount: discoveryDevices.count,
            usedLegacyFallback: usedLegacyFallback,
            includedSystemDefault: includedSystemDefault
        )
    }

    func fetchAudioSnapshot(includeOffline: Bool = true) -> DeviceSnapshot<AudioInputSource> {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let discoveryDevices = discoverySession.devices
        var devices = discoveryDevices
        var usedLegacyFallback = false

        if devices.isEmpty {
            usedLegacyFallback = true
        }

        if let preferred = AVCaptureDevice.default(for: .audio),
           !devices.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            devices.append(preferred)
        }

        let normalized = normalize(devices, includeOffline: includeOffline)
        return DeviceSnapshot(
            devices: normalized.map(AudioInputSource.init(device:)),
            discoveryCount: discoveryDevices.count,
            usedLegacyFallback: usedLegacyFallback,
            includedSystemDefault: false
        )
    }

    private func normalize(_ devices: [AVCaptureDevice], includeOffline: Bool) -> [AVCaptureDevice] {
        let deduplicated = Dictionary(devices.map { ($0.uniqueID, $0) }, uniquingKeysWith: { current, _ in current })
            .values
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        if includeOffline {
            return deduplicated
        }
        return deduplicated.filter { $0.isConnected && !$0.isSuspended }
    }
}

struct DeviceSnapshot<Device> {
    let devices: [Device]
    let discoveryCount: Int
    let usedLegacyFallback: Bool
    let includedSystemDefault: Bool
}
