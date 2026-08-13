import AppKit
import Foundation

struct WatermarkLibrarySnapshot: Codable, Equatable {
    var images: [WatermarkLibraryImage] = []
    var textStyles: [WatermarkLibraryTextStyle] = []
}

struct WatermarkLibraryService {
    private let fileManager = FileManager.default
    private let libraryFileName = "watermark-library.json"

    func isAvailable() -> Bool {
        DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory() != nil
    }

    func load() throws -> WatermarkLibrarySnapshot {
        guard let root = DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory() else {
            return WatermarkLibrarySnapshot()
        }
        let directory = root.appendingPathComponent("Watermarks", isDirectory: true)
        let fileURL = directory.appendingPathComponent(libraryFileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return WatermarkLibrarySnapshot()
        }
        let token = try accessToken()
        defer { token.stop() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WatermarkLibrarySnapshot.self, from: Data(contentsOf: fileURL))
        } catch {
            throw WatermarkLibraryError.persistenceFailed
        }
    }

    func importPNG(from sourceURL: URL) throws -> WatermarkLibraryImage {
        guard sourceURL.pathExtension.lowercased() == "png",
              let image = NSImage(contentsOf: sourceURL),
              image.isValid,
              image.size.width > 0,
              image.size.height > 0 else {
            throw WatermarkLibraryError.invalidPNG
        }

        let directory = try ensureDirectory()
        let token = try accessToken()
        defer { token.stop() }
        let fileName = "image-\(UUID().uuidString).png"
        let destination = directory.appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(fileName)
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw WatermarkLibraryError.copyFailed
        }
        return WatermarkLibraryImage(
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            fileName: fileName,
            aspectRatio: Double(image.size.width / image.size.height)
        )
    }

    func imageURL(for image: WatermarkLibraryImage) -> URL? {
        guard let root = DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory() else { return nil }
        return root.appendingPathComponent("Watermarks/Images", isDirectory: true)
            .appendingPathComponent(image.fileName)
    }

    func save(_ snapshot: WatermarkLibrarySnapshot) throws {
        let directory = try ensureDirectory()
        let token = try accessToken()
        defer { token.stop() }
        let fileURL = directory.appendingPathComponent(libraryFileName)
        let temporaryURL = directory.appendingPathComponent(".\(libraryFileName).\(UUID().uuidString).tmp")
        do {
            let data = try JSONEncoder.prettyPrinted.encode(snapshot)
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw WatermarkLibraryError.persistenceFailed
        }
    }

    func deleteImage(_ image: WatermarkLibraryImage) throws {
        let token = try accessToken()
        defer { token.stop() }
        if let url = imageURL(for: image) {
            try? fileManager.removeItem(at: url)
        }
    }

    func revealLibrary() {
        guard let root = DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory() else { return }
        let directory = root.appendingPathComponent("Watermarks", isDirectory: true)
        // The library can be empty on first use, but Finder should still receive a real directory.
        _ = try? ensureDirectory()
        NSWorkspace.shared.open(directory)
    }

    private func ensureDirectory() throws -> URL {
        guard let root = DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory() else {
            throw WatermarkLibraryError.workspaceMissing
        }
        let directory = root.appendingPathComponent("Watermarks", isDirectory: true)
        let images = directory.appendingPathComponent("Images", isDirectory: true)
        let token = try accessToken()
        defer { token.stop() }
        do {
            try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
            return directory
        } catch {
            throw WatermarkLibraryError.persistenceFailed
        }
    }

    private func accessToken() throws -> OutputLocationAccessToken {
        guard let token = DemoFlowOutputDirectoryPolicy.makeVideoCutsAccessToken() else {
            throw WatermarkLibraryError.workspaceMissing
        }
        return token
    }
}

enum WatermarkLibraryError: LocalizedError {
    case workspaceMissing
    case invalidPNG
    case copyFailed
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            return L10n.tr("subdub.watermark.library.workspace_missing")
        case .invalidPNG:
            return L10n.tr("subdub.watermark.error.invalid_png")
        case .copyFailed:
            return L10n.tr("subdub.watermark.error.png_copy")
        case .persistenceFailed:
            return L10n.tr("subdub.watermark.library.persistence_failed")
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
