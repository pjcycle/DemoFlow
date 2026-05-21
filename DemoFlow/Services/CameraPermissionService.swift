//
//  CameraPermissionService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/1.
//

@preconcurrency import AVFoundation
import Foundation

final class CameraPermissionService {
    static let shared = CameraPermissionService()

    private init() {}

    func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestCameraAccess(completion: @escaping (_ granted: Bool, _ status: AVAuthorizationStatus) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            completion(false, cameraAuthorizationStatus())
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            completion(granted, AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    func requestMicrophoneAccess(completion: @escaping (_ granted: Bool, _ status: AVAuthorizationStatus) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            completion(false, microphoneAuthorizationStatus())
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted, AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }
}
