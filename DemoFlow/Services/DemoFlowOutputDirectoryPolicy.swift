//
//  DemoFlowOutputDirectoryPolicy.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/15.
//
//  2026-06-17 整改：录屏 / PiP 录像 / 屏幕画图自动截图默认输出位置改为由用户主动选择
//  （NSOpenPanel 选目录 + security-scoped bookmark 持久化）；未配置时返回 nil，UI 强制引导去设置。
//  2026-07-09 调整：设置页收敛为统一输出工作区。用户选择父目录后，应用在其中创建 `DemoFlow`
//  根目录，并按需懒创建 `Recoding / Pip / Draw / Vido / Music` 子目录。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// 单次访问用户选定目录的句柄：调用方在写入期间持有，写完调 `stopAccessing()`。
final class OutputLocationAccessToken {
    private let url: URL
    private var didStart = false

    init(url: URL) {
        self.url = url
    }

    deinit {
        stop()
    }

    var directoryURL: URL { url }

    func startIfNeeded() -> Bool {
        guard !didStart else { return true }
        didStart = url.startAccessingSecurityScopedResource()
        if didStart {
            return true
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    func stop() {
        guard didStart else { return }
        url.stopAccessingSecurityScopedResource()
        didStart = false
    }
}

struct DemoFlowOutputDirectoryPolicy {
    private static let workspaceRootFolderName = "DemoFlow"
    private static let recordingsFolderName = "Recoding"
    private static let pipRecordingsFolderName = "Pip"
    private static let videoCutsFolderName = "Vido"
    private static let audioFolderName = "Music"
    private static let screenDrawFolderName = "Draw"

    private static let legacyAppFolderName = "DemoFlow"
    private static let legacyOutputsFolderName = "Outputs"
    private static let legacyPipRecordingsFolderName = "PiPRecordings"
    private static let legacyAudioExtractFolderName = "AudioExtract"
    private static let legacyScreenDrawFolderName = "ScreenDraw"
    private static let legacyScreenDrawAutoCapturesFolderName = "AutoCaptures"

    private static let videoCutsLastDirectoryDefaultsKey = "demoflow.output.video_cuts.last_directory"
    private static let screenDrawLastDirectoryDefaultsKey = "demoflow.output.screen_draw.last_directory"
    private static let videoCuttingImportLastDirectoryDefaultsKey = "demoflow.input.video_cutting.last_directory"

    /// 统一输出工作区：用户在设置里选择父目录后，应用在该目录下创建 `DemoFlow/` 根目录。
    private static let workspaceBookmarkDefaultsKey = "demoflow.output.workspace.bookmark"

    /// 兼容旧版本：录屏 / PiP 录像 / 屏幕画图自动截图共用的"用户选定目录" bookmark。
    private static let recordingsBookmarkDefaultsKey = "demoflow.output.recordings.bookmark"

    /// 兼容旧版本：音频工具用户选定的总输出目录 bookmark。
    private static let audioOutputDirectoryBookmarkDefaultsKey = "demoflow.output.audio.directory.bookmark"

    /// 兼容旧版本：音频提取用户选定的"输出 .mp3 文件" bookmark。
    private static let legacyAudioExtractOutputBookmarkDefaultsKey = "demoflow.output.audio_extract.mp3.bookmark"

    // MARK: - 旧目录 API（保留以兼容旧调用点，**不**在新代码里使用）

    static func outputsRootDirectory() throws -> URL {
        let directory = defaultOutputsRootDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    static func recordingsDirectory() throws -> URL {
        let directory = defaultRecordingsDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    static func pipRecordingsDirectory() throws -> URL {
        let directory = defaultOutputsRootDirectory().appendingPathComponent(pipRecordingsFolderName, isDirectory: true)
        try ensureDirectoryExists(directory)
        return directory
    }

    static func preparePiPRecordingsDirectory() throws -> URL {
        try pipRecordingsDirectory()
    }

    static func defaultAudioExtractRootDirectory() -> URL {
        defaultOutputsRootDirectory().appendingPathComponent(legacyAudioExtractFolderName, isDirectory: true)
    }

    static func preferredVideoCutsDirectory() -> URL {
        if let workspaceDirectory = workspaceSubdirectory(named: videoCutsFolderName) {
            return workspaceDirectory
        }
        if let restored = restoredDirectory(forKey: videoCutsLastDirectoryDefaultsKey) {
            return restored
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func prepareVideoCutsDirectory() throws -> URL {
        let directory = preferredVideoCutsDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    static func rememberVideoCutsDirectory(from exportedFileURL: URL) {
        rememberDirectory(forKey: videoCutsLastDirectoryDefaultsKey, from: exportedFileURL)
    }

    static func preferredVideoCuttingImportDirectory() -> URL {
        if let restored = restoredDirectory(forKey: videoCuttingImportLastDirectoryDefaultsKey) {
            return restored
        }
        if let workspaceRoot = outputWorkspaceRootDirectory() {
            return workspaceRoot
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func prepareVideoCuttingImportDirectory() throws -> URL {
        let directory = preferredVideoCuttingImportDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    static func rememberVideoCuttingImportDirectory(from importedFileURL: URL) {
        rememberDirectory(forKey: videoCuttingImportLastDirectoryDefaultsKey, from: importedFileURL)
    }

    static func preferredScreenDrawDirectory() -> URL {
        if let workspaceDirectory = workspaceSubdirectory(named: screenDrawFolderName) {
            return workspaceDirectory
        }
        if let restored = restoredDirectory(forKey: screenDrawLastDirectoryDefaultsKey) {
            return restored
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func prepareScreenDrawDirectory() throws -> URL {
        let directory = preferredScreenDrawDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    static func rememberScreenDrawDirectory(from exportedFileURL: URL) {
        rememberDirectory(forKey: screenDrawLastDirectoryDefaultsKey, from: exportedFileURL)
    }

    static func preferredScreenDrawAutoCaptureDirectory() -> URL {
        if let workspaceDirectory = workspaceSubdirectory(named: screenDrawFolderName) {
            return workspaceDirectory
        }
        return defaultScreenDrawDirectory().appendingPathComponent(legacyScreenDrawAutoCapturesFolderName, isDirectory: true)
    }

    static func prepareScreenDrawAutoCaptureDirectory() throws -> URL {
        let directory = preferredScreenDrawAutoCaptureDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    // MARK: - 录屏 / PiP / 屏幕画图自动截图 共用：用户选定目录（合规整改后主路径）

    /// 是否已配置统一输出工作区。
    static func outputWorkspaceConfigured() -> Bool {
        outputWorkspaceRootDirectory() != nil
    }

    /// 当前统一输出工作区根目录（`.../DemoFlow`）。
    static func outputWorkspaceRootDirectory() -> URL? {
        if let workspaceBase = resolveWorkspaceBaseDirectoryURL() {
            return prepareWorkspaceRootDirectory(from: workspaceBase)
        }
        guard let legacyDirectory = resolveLegacyRecordingsDirectoryURL() else {
            return nil
        }
        return ensureDirectoryURL(legacyDirectory)
    }

    /// 是否已配置用户选定的录屏保存目录。
    static func recordingsDirectoryConfigured() -> Bool {
        outputWorkspaceConfigured()
    }

    /// 解析用户选定的录屏保存目录；失败返回 nil（UI 必须按 nil 处理）。
    static func recordingsBookmarkedDirectory() -> URL? {
        if let workspaceDirectory = workspaceSubdirectory(named: recordingsFolderName) {
            return workspaceDirectory
        }
        guard let legacyDirectory = resolveLegacyRecordingsDirectoryURL() else {
            return nil
        }
        return ensureDirectoryURL(legacyDirectory)
    }

    /// 解析 PiP 录像子目录：`DemoFlow/Pip/`，自动 mkdir。
    /// 未配置用户目录时返回 nil。
    static func pipRecordingsBookmarkedDirectory() -> URL? {
        if let workspaceDirectory = workspaceSubdirectory(named: pipRecordingsFolderName) {
            return workspaceDirectory
        }
        guard let root = resolveLegacyRecordingsDirectoryURL() else { return nil }
        let directory = ensureDirectoryURL(root).appendingPathComponent(legacyPipRecordingsFolderName, isDirectory: true)
        _ = withDirectoryAccess(to: ensureDirectoryURL(root)) {
            try ensureDirectoryExists(directory)
        }
        return directory
    }

    /// 解析屏幕画图自动截图子目录：`DemoFlow/Draw/`，自动 mkdir。
    /// 未配置用户目录时返回 nil。
    static func screenDrawAutoCaptureBookmarkedDirectory() -> URL? {
        if let workspaceDirectory = workspaceSubdirectory(named: screenDrawFolderName) {
            return workspaceDirectory
        }
        guard let root = resolveLegacyRecordingsDirectoryURL() else { return nil }
        let directory = ensureDirectoryURL(root)
            .appendingPathComponent(legacyScreenDrawFolderName, isDirectory: true)
            .appendingPathComponent(legacyScreenDrawAutoCapturesFolderName, isDirectory: true)
        _ = withDirectoryAccess(to: ensureDirectoryURL(root)) {
            try ensureDirectoryExists(directory)
        }
        return directory
    }

    /// 申请一个访问 token：调用方在写入期间持有，结束调 `stop()`。
    /// 未配置或解析失败时返回 nil。
    static func makeRecordingsAccessToken() -> OutputLocationAccessToken? {
        let targetURL = resolveWorkspaceBaseDirectoryURL() ?? resolveLegacyRecordingsDirectoryURL()
        guard let url = targetURL else { return nil }
        let token = OutputLocationAccessToken(url: url)
        guard token.startIfNeeded() else { return nil }
        return token
    }

    /// 显示 NSOpenPanel 选目录，保存为 security-scoped bookmark，返回选定 URL。
    /// 用户取消返回 nil。
    @MainActor
    static func requestRecordingsDirectoryPicker() -> URL? {
        requestWorkspaceDirectoryPicker(prompt: L10n.tr("output.location.workspace.choose"))
    }

    /// 清空用户选定的录屏保存目录。
    static func clearRecordingsDirectorySelection() {
        clearOutputWorkspaceSelection()
    }

    // MARK: - 音频工具：用户选定的总输出目录

    /// 解析用户选定的音频总输出目录 URL。
    static func audioOutputDirectoryBookmarkedURL() -> URL? {
        if let workspaceDirectory = workspaceSubdirectory(named: audioFolderName) {
            return workspaceDirectory
        }
        return resolveLegacyAudioOutputDirectoryURL()
    }

    /// 兼容旧调用点：返回音频总输出目录。
    static func audioExtractOutputBookmarkedURL() -> URL? {
        audioOutputDirectoryBookmarkedURL()
    }

    /// 申请一个访问 token（写文件期间持有）。
    static func makeAudioExtractOutputAccessToken() -> OutputLocationAccessToken? {
        let targetURL = resolveWorkspaceBaseDirectoryURL() ?? resolveLegacyAudioOutputDirectoryURL()
        guard let url = targetURL else { return nil }
        let token = OutputLocationAccessToken(url: url)
        guard token.startIfNeeded() else { return nil }
        return token
    }

    /// 显示 NSOpenPanel 选音频总输出目录，保存为 security-scoped bookmark。
    @MainActor
    static func requestAudioOutputDirectoryPicker() -> URL? {
        guard requestWorkspaceDirectoryPicker(prompt: L10n.tr("output.location.workspace.choose")) != nil else {
            return nil
        }
        return audioOutputDirectoryBookmarkedURL()
    }

    /// 兼容旧调用点：现在改为选音频总目录。
    @MainActor
    static func requestAudioExtractOutputPicker(suggestedFileName: String) -> URL? {
        _ = suggestedFileName
        return requestAudioOutputDirectoryPicker()
    }

    /// 清空用户选定的音频总输出目录。
    static func clearAudioOutputDirectorySelection() {
        clearOutputWorkspaceSelection()
    }

    /// 兼容旧调用点。
    static func clearAudioExtractOutputSelection() {
        clearAudioOutputDirectorySelection()
    }

    // MARK: - 内部 helpers

    private static func defaultVideoCutsDirectory() -> URL {
        defaultOutputsRootDirectory().appendingPathComponent(videoCutsFolderName, isDirectory: true)
    }

    private static func defaultVideoCuttingImportDirectory() -> URL {
        defaultRecordingsDirectory()
    }

    private static func defaultScreenDrawDirectory() -> URL {
        defaultOutputsRootDirectory().appendingPathComponent(legacyScreenDrawFolderName, isDirectory: true)
    }

    private static func defaultRecordingsDirectory() -> URL {
        defaultOutputsRootDirectory().appendingPathComponent(recordingsFolderName, isDirectory: true)
    }

    private static func defaultOutputsRootDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(legacyAppFolderName, isDirectory: true)
            .appendingPathComponent(legacyOutputsFolderName, isDirectory: true)
    }

    private static func restoredDirectory(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard !isLegacyMediaLibraryDirectory(url) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return url
    }

    private static func rememberDirectory(forKey key: String, from exportedFileURL: URL) {
        let directory = exportedFileURL.deletingLastPathComponent().standardizedFileURL
        UserDefaults.standard.set(directory.path, forKey: key)
    }

    private static func ensureDirectoryExists(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func isLegacyMediaLibraryDirectory(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let legacyRoots = [
            "\(homePath)/Movies/\(legacyAppFolderName)",
            "\(homePath)/Pictures/\(legacyAppFolderName)"
        ]
        return legacyRoots.contains { root in
            standardizedPath == root || standardizedPath.hasPrefix("\(root)/")
        }
    }

    // MARK: - Bookmark 持久化

    private static func resolveWorkspaceBaseDirectoryURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: workspaceBookmarkDefaultsKey) else {
            return nil
        }
        guard let bookmarkedURL = resolveBookmarkedURL(data: data, defaultsKey: workspaceBookmarkDefaultsKey) else {
            return nil
        }
        return ensureDirectoryURL(bookmarkedURL)
    }

    private static func saveWorkspaceBookmark(for url: URL) {
        do {
            let directoryURL = ensureDirectoryURL(url)
            let data = try directoryURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: workspaceBookmarkDefaultsKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: workspaceBookmarkDefaultsKey)
        }
    }

    private static func clearOutputWorkspaceSelection() {
        UserDefaults.standard.removeObject(forKey: workspaceBookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: recordingsBookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: audioOutputDirectoryBookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyAudioExtractOutputBookmarkDefaultsKey)
    }

    @MainActor
    private static func requestWorkspaceDirectoryPicker(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        let selection = normalizeWorkspaceSelection(from: url)
        guard withDirectoryAccess(to: selection.baseDirectoryURL, {
            try ensureDirectoryExists(selection.rootDirectoryURL)
        }) != nil else {
            return nil
        }

        saveWorkspaceBookmark(for: selection.baseDirectoryURL)
        return selection.rootDirectoryURL
    }

    private static func normalizeWorkspaceSelection(from url: URL) -> (baseDirectoryURL: URL, rootDirectoryURL: URL) {
        let directoryURL = ensureDirectoryURL(url)
        if directoryURL.lastPathComponent == workspaceRootFolderName {
            return (
                baseDirectoryURL: directoryURL.deletingLastPathComponent(),
                rootDirectoryURL: directoryURL
            )
        }
        return (
            baseDirectoryURL: directoryURL,
            rootDirectoryURL: directoryURL.appendingPathComponent(workspaceRootFolderName, isDirectory: true)
        )
    }

    private static func prepareWorkspaceRootDirectory(from baseDirectoryURL: URL) -> URL? {
        let rootDirectoryURL = ensureDirectoryURL(baseDirectoryURL)
            .appendingPathComponent(workspaceRootFolderName, isDirectory: true)
        guard withDirectoryAccess(to: ensureDirectoryURL(baseDirectoryURL), {
            try ensureDirectoryExists(rootDirectoryURL)
        }) != nil else {
            return nil
        }
        return rootDirectoryURL
    }

    private static func workspaceSubdirectory(named folderName: String) -> URL? {
        guard let workspaceBase = resolveWorkspaceBaseDirectoryURL(),
              let workspaceRoot = prepareWorkspaceRootDirectory(from: workspaceBase) else {
            return nil
        }
        let directory = workspaceRoot.appendingPathComponent(folderName, isDirectory: true)
        guard withDirectoryAccess(to: workspaceBase, {
            try ensureDirectoryExists(directory)
        }) != nil else {
            return nil
        }
        return directory
    }

    private static func resolveLegacyRecordingsDirectoryURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: recordingsBookmarkDefaultsKey) else {
            return nil
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                // 失效则清空，下次让用户重选
                UserDefaults.standard.removeObject(forKey: recordingsBookmarkDefaultsKey)
                return nil
            }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: recordingsBookmarkDefaultsKey)
            return nil
        }
    }

    private static func saveRecordingsBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: recordingsBookmarkDefaultsKey)
        } catch {
            // 解析失败不致命，下次再让用户选
            UserDefaults.standard.removeObject(forKey: recordingsBookmarkDefaultsKey)
        }
    }

    private static func resolveLegacyAudioOutputDirectoryURL() -> URL? {
        if let data = UserDefaults.standard.data(forKey: audioOutputDirectoryBookmarkDefaultsKey),
           let resolved = resolveBookmarkedURL(data: data, defaultsKey: audioOutputDirectoryBookmarkDefaultsKey) {
            return ensureDirectoryURL(resolved)
        }

        guard let data = UserDefaults.standard.data(forKey: legacyAudioExtractOutputBookmarkDefaultsKey),
              let resolved = resolveBookmarkedURL(data: data, defaultsKey: legacyAudioExtractOutputBookmarkDefaultsKey) else {
            return nil
        }

        let migratedDirectory = ensureDirectoryURL(resolved)
        saveAudioOutputDirectoryBookmark(for: migratedDirectory)
        UserDefaults.standard.removeObject(forKey: legacyAudioExtractOutputBookmarkDefaultsKey)
        return migratedDirectory
    }

    private static func saveAudioOutputDirectoryBookmark(for url: URL) {
        do {
            let directoryURL = ensureDirectoryURL(url)
            let data = try directoryURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: audioOutputDirectoryBookmarkDefaultsKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: audioOutputDirectoryBookmarkDefaultsKey)
        }
    }

    private static func resolveBookmarkedURL(data: Data, defaultsKey: String) -> URL? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                return nil
            }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return nil
        }
    }

    private static func ensureDirectoryURL(_ url: URL) -> URL {
        if url.hasDirectoryPath {
            return url.standardizedFileURL
        }
        return url.deletingLastPathComponent().standardizedFileURL
    }

    private static func withDirectoryAccess<T>(
        to url: URL,
        _ body: () throws -> T
    ) -> T? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            return try body()
        } catch {
            return nil
        }
    }
}
