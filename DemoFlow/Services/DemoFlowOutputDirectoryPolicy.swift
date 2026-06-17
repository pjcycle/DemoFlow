//
//  DemoFlowOutputDirectoryPolicy.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/15.
//
//  2026-06-17 整改：录屏 / PiP 录像 / 屏幕画图自动截图默认输出位置改为由用户主动选择
//  （NSOpenPanel 选目录 + security-scoped bookmark 持久化）；未配置时返回 nil，UI 强制引导去设置。
//  音频提取 / 视频剪切 落点策略不在本文件统一管控。
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
        return didStart
    }

    func stop() {
        guard didStart else { return }
        url.stopAccessingSecurityScopedResource()
        didStart = false
    }
}

struct DemoFlowOutputDirectoryPolicy {
    private static let appFolderName = "DemoFlow"
    private static let outputsFolderName = "Outputs"
    private static let recordingsFolderName = "Recordings"
    private static let pipRecordingsFolderName = "PiPRecordings"
    private static let videoCutsFolderName = "VideoCuts"
    private static let audioExtractFolderName = "AudioExtract"
    private static let screenDrawFolderName = "ScreenDraw"
    private static let screenDrawAutoCapturesFolderName = "AutoCaptures"

    private static let videoCutsLastDirectoryDefaultsKey = "demoflow.output.video_cuts.last_directory"
    private static let screenDrawLastDirectoryDefaultsKey = "demoflow.output.screen_draw.last_directory"
    private static let videoCuttingImportLastDirectoryDefaultsKey = "demoflow.input.video_cutting.last_directory"

    /// 录屏 / PiP 录像 / 屏幕画图自动截图 共用的"用户选定目录"的安全作用域 bookmark。
    private static let recordingsBookmarkDefaultsKey = "demoflow.output.recordings.bookmark"

    /// 音频提取用户选定的"输出 .mp3 文件"的安全作用域 bookmark。
    private static let audioExtractOutputBookmarkDefaultsKey = "demoflow.output.audio_extract.mp3.bookmark"

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
        defaultOutputsRootDirectory().appendingPathComponent(audioExtractFolderName, isDirectory: true)
    }

    static func preferredVideoCutsDirectory() -> URL {
        if let restored = restoredDirectory(forKey: videoCutsLastDirectoryDefaultsKey) {
            return restored
        }
        return defaultVideoCutsDirectory()
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
        return defaultVideoCuttingImportDirectory()
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
        if let restored = restoredDirectory(forKey: screenDrawLastDirectoryDefaultsKey) {
            return restored
        }
        return defaultScreenDrawDirectory()
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
        // Auto-capture output must be deterministic and sandbox-safe.
        // Do not inherit the remembered manual export directory, which may
        // point outside the app container unless selected by the user.
        defaultScreenDrawDirectory().appendingPathComponent(screenDrawAutoCapturesFolderName, isDirectory: true)
    }

    static func prepareScreenDrawAutoCaptureDirectory() throws -> URL {
        let directory = preferredScreenDrawAutoCaptureDirectory()
        try ensureDirectoryExists(directory)
        return directory
    }

    // MARK: - 录屏 / PiP / 屏幕画图自动截图 共用：用户选定目录（合规整改后主路径）

    /// 是否已配置用户选定的录屏保存目录。
    static func recordingsDirectoryConfigured() -> Bool {
        return resolveRecordingsDirectoryURL() != nil
    }

    /// 解析用户选定的录屏保存目录；失败返回 nil（UI 必须按 nil 处理）。
    static func recordingsBookmarkedDirectory() -> URL? {
        resolveRecordingsDirectoryURL()
    }

    /// 解析 PiP 录像子目录：`用户选定目录/PiPRecordings/`，自动 mkdir。
    /// 未配置用户目录时返回 nil。
    static func pipRecordingsBookmarkedDirectory() -> URL? {
        guard let root = resolveRecordingsDirectoryURL() else { return nil }
        let directory = root.appendingPathComponent(pipRecordingsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 解析屏幕画图自动截图子目录：`用户选定目录/ScreenDraw/AutoCaptures/`，自动 mkdir。
    /// 未配置用户目录时返回 nil。
    static func screenDrawAutoCaptureBookmarkedDirectory() -> URL? {
        guard let root = resolveRecordingsDirectoryURL() else { return nil }
        let directory = root
            .appendingPathComponent(screenDrawFolderName, isDirectory: true)
            .appendingPathComponent(screenDrawAutoCapturesFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 申请一个访问 token：调用方在写入期间持有，结束调 `stop()`。
    /// 未配置或解析失败时返回 nil。
    static func makeRecordingsAccessToken() -> OutputLocationAccessToken? {
        guard let url = resolveRecordingsDirectoryURL() else { return nil }
        let token = OutputLocationAccessToken(url: url)
        guard token.startIfNeeded() else { return nil }
        return token
    }

    /// 显示 NSOpenPanel 选目录，保存为 security-scoped bookmark，返回选定 URL。
    /// 用户取消返回 nil。
    @MainActor
    static func requestRecordingsDirectoryPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.tr("output.location.recordings.choose")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        saveRecordingsBookmark(for: url)
        return url
    }

    /// 清空用户选定的录屏保存目录。
    static func clearRecordingsDirectorySelection() {
        UserDefaults.standard.removeObject(forKey: recordingsBookmarkDefaultsKey)
    }

    // MARK: - 音频提取：用户选定的输出 .mp3 文件（合规整改后主路径）

    /// 解析用户选定的音频输出 .mp3 文件 URL。
    static func audioExtractOutputBookmarkedURL() -> URL? {
        resolveAudioExtractOutputURL()
    }

    /// 申请一个访问 token（写文件期间持有）。
    static func makeAudioExtractOutputAccessToken() -> OutputLocationAccessToken? {
        guard let url = resolveAudioExtractOutputURL() else { return nil }
        let token = OutputLocationAccessToken(url: url)
        guard token.startIfNeeded() else { return nil }
        return token
    }

    /// 显示 NSSavePanel 选输出 .mp3 文件，保存为 security-scoped bookmark。
    @MainActor
    static func requestAudioExtractOutputPicker(suggestedFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.audio, .mp3]
        panel.nameFieldStringValue = suggestedFileName
        panel.prompt = L10n.tr("output.location.audio.choose")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        saveAudioExtractOutputBookmark(for: url)
        return url
    }

    /// 清空用户选定的音频输出位置。
    static func clearAudioExtractOutputSelection() {
        UserDefaults.standard.removeObject(forKey: audioExtractOutputBookmarkDefaultsKey)
    }

    // MARK: - 内部 helpers

    private static func defaultVideoCutsDirectory() -> URL {
        defaultOutputsRootDirectory().appendingPathComponent(videoCutsFolderName, isDirectory: true)
    }

    private static func defaultVideoCuttingImportDirectory() -> URL {
        defaultRecordingsDirectory()
    }

    private static func defaultScreenDrawDirectory() -> URL {
        defaultOutputsRootDirectory().appendingPathComponent(screenDrawFolderName, isDirectory: true)
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
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(outputsFolderName, isDirectory: true)
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
            "\(homePath)/Movies/\(appFolderName)",
            "\(homePath)/Pictures/\(appFolderName)"
        ]
        return legacyRoots.contains { root in
            standardizedPath == root || standardizedPath.hasPrefix("\(root)/")
        }
    }

    // MARK: - Bookmark 持久化

    private static func resolveRecordingsDirectoryURL() -> URL? {
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

    private static func resolveAudioExtractOutputURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: audioExtractOutputBookmarkDefaultsKey) else {
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
                UserDefaults.standard.removeObject(forKey: audioExtractOutputBookmarkDefaultsKey)
                return nil
            }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: audioExtractOutputBookmarkDefaultsKey)
            return nil
        }
    }

    private static func saveAudioExtractOutputBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: audioExtractOutputBookmarkDefaultsKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: audioExtractOutputBookmarkDefaultsKey)
        }
    }
}
