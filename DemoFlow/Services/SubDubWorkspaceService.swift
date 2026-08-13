import AppKit
import Foundation
import UniformTypeIdentifiers

struct SubDubWorkspaceService {
    let fileManager = FileManager.default

    var videoTypes: [UTType] { [.mpeg4Movie, .quickTimeMovie] }
    var videoConversionTypes: [UTType] {
        let webMType = UTType(filenameExtension: "webm", conformingTo: .movie)
            ?? UTType(filenameExtension: "webm")
            ?? .data
        return [.movie, .mpeg4Movie, .quickTimeMovie, webMType]
    }
    var audioTypes: [UTType] { [.mp3, .mpeg4Audio, .wav, .aiff, .audio] }
    var subtitleTypes: [UTType] { [.plainText] }
    var timelineJSONTypes: [UTType] { [.json] }

    func makeSessionDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("SubDub", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func persistInput(from url: URL, kind: SubDubFileKind, sessionDirectory: URL) throws -> URL {
        let resolvedURL = url.standardizedFileURL
        guard resolvedURL.isFileURL, fileManager.fileExists(atPath: resolvedURL.path) else {
            throw SubDubError.inputUnavailable
        }
        guard isSupported(resolvedURL, kind: kind) else {
            switch kind {
            case .video: throw SubDubError.unsupportedVideo
            case .audio: throw SubDubError.unsupportedAudio
            case .subtitle: throw SubDubError.unsupportedSubtitle
            }
        }

        let isAccessingSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        let folderName: String
        let fallbackExtension: String
        switch kind {
        case .video:
            folderName = "Video"
            fallbackExtension = "mov"
        case .audio:
            folderName = "Audio"
            fallbackExtension = "m4a"
        case .subtitle:
            folderName = "Subtitle"
            fallbackExtension = "srt"
        }

        let folder = sessionDirectory.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = resolvedURL.pathExtension.isEmpty ? fallbackExtension : resolvedURL.pathExtension
        let destination = folder.appendingPathComponent("input_\(UUID().uuidString).\(ext)")
        do {
            try fileManager.copyItem(at: resolvedURL, to: destination)
            return destination
        } catch {
            throw SubDubError.inputUnavailable
        }
    }

    @MainActor
    func pickVideoURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_video"),
            types: videoTypes,
            directory: DemoFlowOutputDirectoryPolicy.preferredVideoCuttingImportDirectory()
        )
    }

    @MainActor
    func pickVideoConversionURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_video"),
            types: videoConversionTypes,
            directory: DemoFlowOutputDirectoryPolicy.preferredVideoCuttingImportDirectory()
        )
    }

    @MainActor
    func pickAudioURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_audio"),
            types: audioTypes,
            directory: DemoFlowOutputDirectoryPolicy.audioOutputDirectoryBookmarkedURL()
        )
    }

    @MainActor
    func pickSubtitleURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_subtitle"),
            types: subtitleTypes,
            directory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    @MainActor
    func pickTimelineJSONURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_timeline_json"),
            types: timelineJSONTypes,
            directory: DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory()
        )
    }

    @MainActor
    func pickTimelineJSONOutputURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.tr("subdub.action.export_timeline_json")
        panel.allowedContentTypes = timelineJSONTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = DemoFlowOutputDirectoryPolicy.outputWorkspaceRootDirectory()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    func pickTextURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_text"),
            types: [.plainText],
            directory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    @MainActor
    func pickWatermarkPNGURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.watermark.action.choose_png"),
            types: [.png],
            directory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    func persistWatermarkPNG(from url: URL, sessionDirectory: URL) throws -> WatermarkImageReplacement {
        let resolvedURL = url.standardizedFileURL
        guard resolvedURL.pathExtension.lowercased() == "png",
              fileManager.fileExists(atPath: resolvedURL.path) else {
            throw WatermarkAssetError.invalidPNG
        }

        let isAccessingSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: resolvedURL),
              image.isValid,
              image.size.width > 0,
              image.size.height > 0 else {
            throw WatermarkAssetError.invalidPNG
        }

        let directory = sessionDirectory.appendingPathComponent("WatermarkAssets", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("watermark-")
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("png")
        do {
            try fileManager.copyItem(at: resolvedURL, to: destination)
        } catch {
            throw WatermarkAssetError.copyFailed
        }

        return WatermarkImageReplacement(
            assetURL: destination,
            aspectRatio: image.size.width / image.size.height,
            rectNormalized: .full
        )
    }

    func deleteWatermarkPNG(_ replacement: WatermarkImageReplacement?) {
        guard let replacement else { return }
        try? fileManager.removeItem(at: replacement.assetURL)
    }

    func clearWatermarkAssets(in sessionDirectory: URL?) {
        guard let sessionDirectory else { return }
        let directory = sessionDirectory.appendingPathComponent("WatermarkAssets", isDirectory: true)
        try? fileManager.removeItem(at: directory)
    }

    @MainActor
    func pickVideoOutputURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.tr("subdub.action.export_video")
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = try? DemoFlowOutputDirectoryPolicy.prepareVideoCutsDirectory()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    func pickAudioOutputURL(suggestedName: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.tr("subdub.action.export_audio")
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = DemoFlowOutputDirectoryPolicy.audioOutputDirectoryBookmarkedURL()
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func isSupported(_ url: URL, kind: SubDubFileKind) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .video:
            return ["mp4", "mov", "m4v", "webm"].contains(ext)
        case .audio:
            return ["mp3", "aac", "wav", "wave", "m4a", "aiff", "aif"].contains(ext)
        case .subtitle:
            return ["srt", "vtt"].contains(ext)
        }
    }

    private func pickURL(title: String, types: [UTType], directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

enum WatermarkAssetError: LocalizedError {
    case invalidPNG
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .invalidPNG:
            return L10n.tr("subdub.watermark.error.invalid_png")
        case .copyFailed:
            return L10n.tr("subdub.watermark.error.png_copy")
        }
    }
}
