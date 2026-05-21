//
//  ScreenDrawAutoCaptureService.swift
//  DemoFlow
//
//  Created by Codex on 2026/5/15.
//

import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenDrawAutoCaptureError: LocalizedError {
    case screenUnavailable
    case screenCapturePermissionDenied
    case screenCaptureFailed
    case canvasUnavailable
    case bitmapInitFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .screenUnavailable:
            return L10n.tr("draw.capture.error.screen_unavailable")
        case .screenCapturePermissionDenied:
            return L10n.tr("draw.capture.error.permission")
        case .screenCaptureFailed:
            return L10n.tr("draw.capture.error.capture_failed")
        case .canvasUnavailable:
            return L10n.tr("draw.capture.error.canvas_unavailable")
        case .bitmapInitFailed:
            return L10n.tr("draw.capture.error.bitmap_failed")
        case .pngEncodingFailed:
            return L10n.tr("draw.capture.error.png_failed")
        }
    }
}

struct ScreenDrawAutoCaptureService {
    private let retentionDays = 3

    func captureAndSave(
        screen: NSScreen?,
        canvasImage: NSImage
    ) async throws -> URL {
        guard let screen else {
            throw ScreenDrawAutoCaptureError.screenUnavailable
        }
        guard hasScreenCapturePermission() else {
            throw ScreenDrawAutoCaptureError.screenCapturePermissionDenied
        }
        let screenImage = try await captureScreenImage(screen)
        guard let composed = compose(screenImage: screenImage, canvasImage: canvasImage) else {
            throw ScreenDrawAutoCaptureError.canvasUnavailable
        }

        let directory = try DemoFlowOutputDirectoryPolicy.prepareScreenDrawAutoCaptureDirectory()
        let outputURL = directory.appendingPathComponent(fileName(), isDirectory: false)
        try writePNG(from: composed, to: outputURL)
        try cleanupExpiredFiles(in: directory)
        return outputURL
    }

    private func hasScreenCapturePermission() -> Bool {
        if #available(macOS 11.0, *) {
            if CGPreflightScreenCaptureAccess() {
                return true
            }
            // Trigger system prompt proactively so first failure is actionable.
            _ = CGRequestScreenCaptureAccess()
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    private func captureScreenImage(_ screen: NSScreen) async throws -> NSImage {
        let captureRect = screen.visibleFrame
        guard captureRect.width > 1, captureRect.height > 1 else {
            throw ScreenDrawAutoCaptureError.screenCaptureFailed
        }
        let cgImage = try await captureDisplayImage(in: captureRect)
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private func compose(screenImage: NSImage, canvasImage: NSImage) -> NSImage? {
        guard screenImage.size.width > 1, screenImage.size.height > 1 else { return nil }
        let composed = NSImage(size: screenImage.size)
        composed.lockFocus()
        defer { composed.unlockFocus() }

        let targetRect = NSRect(origin: .zero, size: screenImage.size)
        screenImage.draw(in: targetRect)
        canvasImage.draw(in: targetRect)
        return composed
    }

    private func writePNG(from image: NSImage, to outputURL: URL) throws {
        guard let tiffData = image.tiffRepresentation else {
            throw ScreenDrawAutoCaptureError.bitmapInitFailed
        }
        guard let bitmap = NSBitmapImageRep(data: tiffData) else {
            throw ScreenDrawAutoCaptureError.bitmapInitFailed
        }
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenDrawAutoCaptureError.pngEncodingFailed
        }
        try pngData.write(to: outputURL, options: .atomic)
    }

    private func cleanupExpiredFiles(in directory: URL) throws {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey])
            guard values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? values.creationDate ?? .distantFuture
            if date < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "draw_capture_\(formatter.string(from: Date())).png"
    }

    private func captureDisplayImage(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image {
                    continuation.resume(returning: image)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(throwing: ScreenDrawAutoCaptureError.screenCaptureFailed)
            }
        }
    }
}
