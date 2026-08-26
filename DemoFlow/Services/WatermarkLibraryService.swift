import AppKit
import Foundation
import ImageIO

struct WatermarkLibrarySnapshot: Codable, Equatable {
    var images: [WatermarkLibraryImage] = []
    var textStyles: [WatermarkLibraryTextStyle] = []
}

struct WatermarkLibraryService {
    private static let maximumPNGFileByteCount = 10 * 1024 * 1024
    private static let maximumPNGDimension = 4_096

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
        guard sourceURL.pathExtension.lowercased() == "png" else {
            throw WatermarkLibraryError.invalidPNG
        }
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value > 0 else {
            throw WatermarkLibraryError.invalidPNG
        }
        guard byteCount.int64Value <= Int64(Self.maximumPNGFileByteCount) else {
            throw WatermarkLibraryError.pngFileTooLarge
        }
        guard let pixelSize = pngPixelSize(at: sourceURL) else {
            throw WatermarkLibraryError.invalidPNG
        }
        guard max(pixelSize.width, pixelSize.height) <= CGFloat(Self.maximumPNGDimension) else {
            throw WatermarkLibraryError.pngDimensionsTooLarge
        }
        guard let image = NSImage(contentsOf: sourceURL), image.isValid else {
            throw WatermarkLibraryError.invalidPNG
        }

        let directory = try ensureDirectory()
        let token = try accessToken()
        defer { token.stop() }
        let fileName = "image-\(UUID().uuidString).png"
        let destination = directory.appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw WatermarkLibraryError.copyFailed
        }
        return WatermarkLibraryImage(
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            fileName: fileName,
            aspectRatio: Double(pixelSize.width / pixelSize.height)
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

    private func pngPixelSize(at url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

enum WatermarkLibraryError: LocalizedError {
    case workspaceMissing
    case invalidPNG
    case pngFileTooLarge
    case pngDimensionsTooLarge
    case copyFailed
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            return L10n.tr("subdub.watermark.library.workspace_missing")
        case .invalidPNG:
            return L10n.tr("subdub.watermark.error.invalid_png")
        case .pngFileTooLarge:
            return L10n.tr("subdub.watermark.error.png_file_too_large")
        case .pngDimensionsTooLarge:
            return L10n.tr("subdub.watermark.error.png_dimensions_too_large")
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
