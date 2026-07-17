//
//  SubscriptionDiagnosticsStore.swift
//  DemoFlow
//
//  Stable, user-accessible diagnostics for StoreKit subscription testing.
//

import AppKit
import Foundation

final class SubscriptionDiagnosticsStore {
    static let shared = SubscriptionDiagnosticsStore()

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatter = formatter
    }

    var logFileURL: URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser

        return applicationSupportURL
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("subscription.log", isDirectory: false)
    }

    func ensureLogFile() {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }
        } catch {
            NSLog("[SubscriptionDiagnostics] Cannot create log file: %@", String(describing: error))
        }
    }

    func append(_ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] [pid=\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"

        lock.lock()
        defer { lock.unlock() }

        do {
            let directoryURL = logFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = Data(line.utf8)

            if !fileManager.fileExists(atPath: logFileURL.path) {
                try data.write(to: logFileURL, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("[SubscriptionDiagnostics] Cannot append log: %@", String(describing: error))
        }
    }

    func openLogFile() {
        ensureLogFile()
        if !NSWorkspace.shared.open(logFileURL) {
            NSWorkspace.shared.selectFile(logFileURL.path, inFileViewerRootedAtPath: "")
        }
    }
}
