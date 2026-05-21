//
//  FFmpegBinaryService.swift
//  DemoFlow
//
//  Created by Codex on 2026/5/12.
//

import Foundation

struct FFmpegBinaryService {
    private let fileManager = FileManager.default
    private var helpersDirectoryURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
    }

    func ensureReady() throws -> FFmpegToolPaths {
        guard isAppleSilicon else {
            throw FFmpegError.unsupportedArchitecture
        }

        if let bundlePaths = bundledToolPaths() {
            if (try? validateToolPair(bundlePaths)) != nil {
                return bundlePaths
            }

            // Fallback to Application Support copy when direct bundle execution fails.
            if let installed = try? installAndValidateBundlePair(bundlePaths) {
                return installed
            }
        }

        if let systemPaths = discoverSystemToolPaths() {
            if (try? validateToolPair(systemPaths)) != nil {
                return systemPaths
            }
        }

        throw FFmpegError.missingBundledBinary("ffmpeg/ffprobe")
    }

    private func validateToolPair(_ paths: FFmpegToolPaths) throws {
        try validateTool(at: paths.ffmpegURL)
        try validateTool(at: paths.ffprobeURL)
    }

    private func installAndValidateBundlePair(_ bundlePaths: FFmpegToolPaths) throws -> FFmpegToolPaths {
        let installRoot = try ensureInstallRoot()
        let installed = FFmpegToolPaths(
            ffmpegURL: installRoot.appendingPathComponent("ffmpeg"),
            ffprobeURL: installRoot.appendingPathComponent("ffprobe")
        )
        try installOrUpdateBinary(from: bundlePaths.ffmpegURL, to: installed.ffmpegURL)
        try installOrUpdateBinary(from: bundlePaths.ffprobeURL, to: installed.ffprobeURL)
        try ensureExecutablePermission(at: installed.ffmpegURL)
        try ensureExecutablePermission(at: installed.ffprobeURL)
        try validateToolPair(installed)
        return installed
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private func bundledToolPaths() -> FFmpegToolPaths? {
        guard let ffmpegURL = resolveBundledBinary(named: "ffmpeg"),
              let ffprobeURL = resolveBundledBinary(named: "ffprobe") else { return nil }
        return FFmpegToolPaths(ffmpegURL: ffmpegURL, ffprobeURL: ffprobeURL)
    }

    private func resolveBundledBinary(named name: String) -> URL? {
        var candidates: [URL] = []

        if let helpersDirectoryURL {
            candidates.append(helpersDirectoryURL.appendingPathComponent(name))
        }
        if let builtInPlugInsURL = Bundle.main.builtInPlugInsURL {
            candidates.append(builtInPlugInsURL.appendingPathComponent(name))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name))
        }
        if let direct = Bundle.main.url(forResource: name, withExtension: nil) {
            candidates.append(direct)
        }
        if let legacy = Bundle.main.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "ThirdParty/ffmpeg/arm64"
        ) {
            candidates.append(legacy)
        }

        var visited = Set<String>()
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            let path = resolved.path
            guard visited.insert(path).inserted else { continue }
            if fileManager.fileExists(atPath: path) {
                return resolved
            }
        }

        return nil
    }

    private func discoverSystemToolPaths() -> FFmpegToolPaths? {
        let candidates = [
            (
                ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                ffprobe: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
            ),
            (
                ffmpeg: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
                ffprobe: URL(fileURLWithPath: "/usr/local/bin/ffprobe")
            )
        ]

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.ffmpeg.path),
               fileManager.fileExists(atPath: candidate.ffprobe.path) {
                return FFmpegToolPaths(
                    ffmpegURL: candidate.ffmpeg,
                    ffprobeURL: candidate.ffprobe
                )
            }
        }
        return nil
    }

    private func ensureInstallRoot() throws -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("ffmpeg", isDirectory: true)
        guard let root else {
            throw FFmpegError.installPathUnavailable
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func installOrUpdateBinary(from source: URL, to destination: URL) throws {
        let sourceResolved = source.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: sourceResolved.path) else {
            throw FFmpegError.missingBundledBinary(source.lastPathComponent)
        }

        if fileManager.fileExists(atPath: destination.path) {
            let srcSize = fileSize(for: sourceResolved)
            let dstSize = fileSize(for: destination)
            if srcSize == dstSize, srcSize > 0 {
                return
            }
            do {
                try fileManager.removeItem(at: destination)
            } catch {
                throw FFmpegError.installCopyFailed(destination.lastPathComponent, error.localizedDescription)
            }
        }

        do {
            try fileManager.copyItem(at: sourceResolved, to: destination)
        } catch {
            throw FFmpegError.installCopyFailed(destination.lastPathComponent, error.localizedDescription)
        }
    }

    private func ensureExecutablePermission(at url: URL) throws {
        // Some builds already carry executable bit; avoid failing the whole pipeline
        // when sandbox/filesystem does not allow attribute mutation.
        if fileManager.isExecutableFile(atPath: url.path) {
            return
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int(0o755))],
                ofItemAtPath: url.path
            )
        } catch {
            // best effort; validation below decides final executability
        }
    }

    private func fileSize(for url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func validateTool(at url: URL) throws {
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw FFmpegError.permissionSetupFailed(url.lastPathComponent)
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["-version"]
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FFmpegError.binaryValidationFailed(url.lastPathComponent, error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw FFmpegError.binaryValidationFailed(url.lastPathComponent, "exit=\(process.terminationStatus)")
        }
    }
}

extension FFmpegBinaryService {
    enum FFmpegError: LocalizedError {
        case unsupportedArchitecture
        case installPathUnavailable
        case missingBundledBinary(String)
        case installCopyFailed(String, String)
        case permissionSetupFailed(String)
        case binaryValidationFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupportedArchitecture:
                return L10n.tr("legacy.ffmpeg.unsupported_arch")
            case .installPathUnavailable:
                return L10n.tr("legacy.ffmpeg.install_path_unavailable")
            case let .missingBundledBinary(name):
                return L10n.f("fmt.ffmpeg.missing_bundled_binary", name)
            case let .installCopyFailed(name, reason):
                return L10n.f("fmt.ffmpeg.install_copy_failed", name, reason)
            case let .permissionSetupFailed(name):
                return L10n.f("fmt.ffmpeg.permission_setup_failed", name)
            case let .binaryValidationFailed(name, reason):
                return L10n.f("fmt.ffmpeg.binary_validation_failed", name, reason)
            }
        }
    }
}
