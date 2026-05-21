//
//  PiPFilmRecorderService.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/17.
//

import AVFoundation
import Combine
import Foundation

private struct PiPFilmExporterBox: @unchecked Sendable {
    let exporter: AVAssetExportSession
}

enum PiPFilmRecorderServiceError: LocalizedError {
    case invalidState
    case cameraPermissionDenied
    case microphonePermissionDenied
    case missingCameraSelection
    case missingMicrophoneSelection
    case notRecording
    case exportSessionInitFailed
    case exportFailed
    case exportCancelled
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
        case .exportSessionInitFailed:
            return L10n.tr("pip.film.error.export_session")
        case .exportFailed:
            return L10n.tr("pip.film.error.export_failed")
        case .exportCancelled:
            return L10n.tr("pip.film.error.export_cancelled")
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
    private var pendingRawRecordingURL: URL?
    private var pendingFinalOutputURL: URL?

    func startRecording(
        with runtime: PiPPreviewRuntime,
        outputDirectory: URL
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
        let rawRecordingURL = try makeRawRecordingURL()
        let finalOutputURL = try makeFinalOutputURL(in: outputDirectory)
        pendingRawRecordingURL = rawRecordingURL
        pendingFinalOutputURL = finalOutputURL

        runtime.selectSource(withID: snapshot.videoDeviceID)
        if let audioDeviceID = snapshot.audioDeviceID {
            runtime.selectAudioSource(withID: audioDeviceID)
        }
        runtime.startPreviewIfNeeded()

        do {
            try await runtime.startRecording(
                to: rawRecordingURL,
                snapshot: snapshot
            )
            state = .recording
        } catch {
            cleanupPendingFiles(removeFinalOutputIfExists: true)
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
            let rawURL = try await runtime.stopRecording()
            let finalURL: URL
            if let pendingFinalOutputURL {
                finalURL = pendingFinalOutputURL
            } else {
                finalURL = try makeFinalOutputURL(
                    in: DemoFlowOutputDirectoryPolicy.preparePiPRecordingsDirectory()
                )
            }
            try await exportToMP4(from: rawURL, to: finalURL)
            try validateOutput(finalURL)
            lastOutputURL = finalURL
            cleanupPendingFiles(removeFinalOutputIfExists: false)
            state = .idle
            return finalURL
        } catch {
            cleanupPendingFiles(removeFinalOutputIfExists: true)
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

    private func makeRawRecordingURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("pip-film", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let stamp = formatter.string(from: Date())
        return root.appendingPathComponent("pip_raw_\(stamp).mov")
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

    private func exportToMP4(from inputURL: URL, to outputURL: URL) async throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: inputURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw PiPFilmRecorderServiceError.exportSessionInitFailed
        }

        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .mp4)
        } else {
            let exporterBox = PiPFilmExporterBox(exporter: exporter)
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            exporter.shouldOptimizeForNetworkUse = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporterBox.exporter.exportAsynchronously {
                    switch exporterBox.exporter.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .failed:
                        continuation.resume(throwing: exporterBox.exporter.error ?? PiPFilmRecorderServiceError.exportFailed)
                    case .cancelled:
                        continuation.resume(throwing: PiPFilmRecorderServiceError.exportCancelled)
                    default:
                        continuation.resume(throwing: PiPFilmRecorderServiceError.exportFailed)
                    }
                }
            }
        }

        if fileManager.fileExists(atPath: inputURL.path) {
            try? fileManager.removeItem(at: inputURL)
        }
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

    private func cleanupPendingFiles(removeFinalOutputIfExists: Bool) {
        if let pendingRawRecordingURL,
           fileManager.fileExists(atPath: pendingRawRecordingURL.path) {
            try? fileManager.removeItem(at: pendingRawRecordingURL)
        }

        if removeFinalOutputIfExists,
           let pendingFinalOutputURL,
           fileManager.fileExists(atPath: pendingFinalOutputURL.path) {
            try? fileManager.removeItem(at: pendingFinalOutputURL)
        }

        pendingRawRecordingURL = nil
        pendingFinalOutputURL = nil
    }

    private func readableMessage(for error: Error) -> String {
        if let serviceError = error as? PiPFilmRecorderServiceError {
            return serviceError.errorDescription ?? serviceError.localizedDescription
        }
        return error.localizedDescription
    }
}
