import AppKit
import Foundation
import UniformTypeIdentifiers

struct SubDubWorkspaceService {
    let fileManager = FileManager.default

    var videoTypes: [UTType] { [.mpeg4Movie, .quickTimeMovie] }
    var audioTypes: [UTType] { [.mp3, .mpeg4Audio, .wav, .aiff, .audio] }
    var subtitleTypes: [UTType] { [.plainText] }

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
    func pickTextURL() -> URL? {
        pickURL(
            title: L10n.tr("subdub.action.import_text"),
            types: [.plainText],
            directory: FileManager.default.homeDirectoryForCurrentUser
        )
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
            return ["mp4", "mov"].contains(ext)
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
