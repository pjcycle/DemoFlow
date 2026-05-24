//
//  PiPFilmRecorderService.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/17.
//

import AVFoundation
import Combine
import Foundation

enum PiPFilmRecorderServiceError: LocalizedError {
    case invalidState
    case cameraPermissionDenied
    case microphonePermissionDenied
    case missingCameraSelection
    case missingMicrophoneSelection
    case notRecording
    case outputMissing
    case outputEmpty
    case fileNameExhausted
    case runtimeStartFailed(String)
    case runtimeStopFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return L10n.tr("pip.film.error.invalid_state")
        case .cameraPermissionDenied:
            return L10n.tr("pip.film.error.camera_permission")
        case .microphonePermissionDenied:
            return L10n.tr("pip.film.error.microphone_permission")
        case .missingCameraSelection:
            return L10n.tr("pip.film.error.missing_camera")
        case .missingMicrophoneSelection:
            return L10n.tr("pip.film.error.missing_microphone")
        case .notRecording:
            return L10n.tr("pip.film.error.not_recording")
        case .outputMissing:
            return L10n.tr("pip.film.error.output_missing")
        case .outputEmpty:
            return L10n.tr("pip.film.error.output_empty")
        case .fileNameExhausted:
            return L10n.tr("pip.film.error.file_name_exhausted")
        case let .runtimeStartFailed(message):
            return L10n.f("pip.film.error.runtime_start", message)
        case let .runtimeStopFailed(message):
            return L10n.f("pip.film.error.runtime_stop", message)
        }
    }
}

@MainActor
final class PiPFilmRecorderService: ObservableObject {
    @Published private(set) var state: PiPFilmRecordingState = .idle
    @Published private(set) var lastOutputURL: URL?

    private let fileManager = FileManager.default
    private var pendingFinalOutputURL: URL?

    func startRecording(
        with runtime: PiPPreviewRuntime,
        outputDirectory: URL,
        qualityConfig: PiPRecordingQualityConfig
    ) async throws {
        guard !state.isBusy, !state.isRecording else {
            throw PiPFilmRecorderServiceError.invalidState
        }
        guard runtime.authorizationStatus == .authorized else {
            throw PiPFilmRecorderServiceError.cameraPermissionDenied
        }
        guard runtime.microphoneAuthorizationStatus == .authorized else {
            throw PiPFilmRecorderServiceError.microphonePermissionDenied
        }
        guard let snapshot = runtime.sessionSnapshot else {
            throw PiPFilmRecorderServiceError.missingCameraSelection
        }
        guard snapshot.audioDeviceID != nil else {
            throw PiPFilmRecorderServiceError.missingMicrophoneSelection
        }

        state = .preparing
        let finalOutputURL = try makeFinalOutputURL(in: outputDirectory)
        pendingFinalOutputURL = finalOutputURL

        runtime.selectSource(withID: snapshot.videoDeviceID)
        if let audioDeviceID = snapshot.audioDeviceID {
            runtime.selectAudioSource(withID: audioDeviceID)
        }
        runtime.startPreviewIfNeeded()

        do {
            try await runtime.startRecording(
                to: finalOutputURL,
                snapshot: snapshot,
                qualityConfig: qualityConfig
            )
            state = .recording
        } catch {
            cleanupPendingFiles(removeOutputIfExists: true)
            state = .failed(readableMessage(for: error))
            throw PiPFilmRecorderServiceError.runtimeStartFailed(readableMessage(for: error))
        }
    }

    func stopRecording(with runtime: PiPPreviewRuntime) async throws -> URL {
        guard state.isRecording else {
            throw PiPFilmRecorderServiceError.notRecording
        }

        state = .stopping

        do {
            let outputURL = try await runtime.stopRecording()
            let finalURL = pendingFinalOutputURL ?? outputURL
            try validateOutput(finalURL)
            lastOutputURL = finalURL
            cleanupPendingFiles(removeOutputIfExists: false)
            state = .idle
            return finalURL
        } catch {
            cleanupPendingFiles(removeOutputIfExists: true)
            let message = readableMessage(for: error)
            state = .failed(message)
            throw PiPFilmRecorderServiceError.runtimeStopFailed(message)
        }
    }

    func resetFailureIfNeeded() {
        if case .failed = state {
            state = .idle
        }
    }

    func handleRuntimeFailure(_ error: Error) {
        guard state.isRecording || state.isBusy else { return }
        cleanupPendingFiles(removeOutputIfExists: true)
        state = .failed(readableMessage(for: error))
    }

    private func makeFinalOutputURL(in outputDirectory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        let baseName = "pip_\(timestamp)"
        let initial = outputDirectory.appendingPathComponent("\(baseName).mp4")
        if !fileManager.fileExists(atPath: initial.path) {
            return initial
        }

        var index = 1
        while index < 999 {
            let candidate = outputDirectory.appendingPathComponent("\(baseName)_\(index).mp4")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }

        throw PiPFilmRecorderServiceError.fileNameExhausted
    }

    private func validateOutput(_ outputURL: URL) throws {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw PiPFilmRecorderServiceError.outputMissing
        }
        let attrs = try fileManager.attributesOfItem(atPath: outputURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw PiPFilmRecorderServiceError.outputEmpty
        }
    }

    private func cleanupPendingFiles(removeOutputIfExists: Bool) {
        if removeOutputIfExists,
           let pendingFinalOutputURL,
           fileManager.fileExists(atPath: pendingFinalOutputURL.path) {
            try? fileManager.removeItem(at: pendingFinalOutputURL)
        }

        pendingFinalOutputURL = nil
    }

    private func readableMessage(for error: Error) -> String {
        if let serviceError = error as? PiPFilmRecorderServiceError {
            return serviceError.errorDescription ?? serviceError.localizedDescription
        }
        return error.localizedDescription
    }
}
