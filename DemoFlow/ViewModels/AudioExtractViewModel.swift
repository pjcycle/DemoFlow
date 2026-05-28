//
//  AudioExtractViewModel.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/12.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AudioExtractViewModel: ObservableObject {
    @Published var sourceType: AudioExtractSourceType = .localFile
    @Published var localFileURL: URL?
    @Published var sourceURLString: String = ""
    @Published var outputRootURL: URL = DemoFlowOutputDirectoryPolicy.defaultAudioExtractRootDirectory()
    @Published var quality: AudioExtractQualityPreset = .best
    @Published var installDependencies = true

    @Published private(set) var isExtracting = false
    @Published private(set) var statusMessage: String = L10n.tr("audio.extract.status.idle")
    @Published private(set) var logs: [String] = []
    @Published private(set) var latestOutputDirectoryURL: URL?
    @Published private(set) var latestMP3URL: URL?

    private let service = AudioExtractService()
    private var extractionTask: Task<Void, Never>?

    var canStart: Bool {
        guard !isExtracting else { return false }
        switch sourceType {
        case .localFile:
            return localFileURL != nil
        case .onlineURL:
            return !sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var canStop: Bool {
        isExtracting
    }

    var outputRootPathText: String {
        outputRootURL.path
    }

    var localFilePathText: String {
        localFileURL?.path ?? L10n.tr("audio.extract.placeholder.local_empty")
    }

    func pickLocalFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .mpeg4Movie,
            .quickTimeMovie,
            .audio,
            .movie,
            .fileURL
        ]
        panel.prompt = L10n.tr("audio.extract.action.select_file")

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            appendLog("[input] \(L10n.tr("audio.extract.status.file_pick_cancelled"))")
            return
        }

        guard url.isSupportedAudioExtractLocalFile else {
            statusMessage = L10n.tr("audio.extract.error.unsupported_local")
            appendLog("[error] \(statusMessage)")
            return
        }

        localFileURL = url
        statusMessage = L10n.f("audio.extract.status.local_selected", url.lastPathComponent)
        appendLog("[input] \(statusMessage)")
    }

    func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("audio.extract.action.select_output")

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            appendLog("[output] \(L10n.tr("audio.extract.status.output_pick_cancelled"))")
            return
        }

        outputRootURL = url
        statusMessage = L10n.f("audio.extract.status.output_selected", url.path)
        appendLog("[output] \(statusMessage)")
    }

    func startExtraction() {
        guard canStart else {
            statusMessage = L10n.tr("audio.extract.error.missing_input")
            appendLog("[error] \(statusMessage)")
            return
        }

        isExtracting = true
        statusMessage = L10n.tr("audio.extract.status.running")
        appendLog("[run] \(statusMessage)")

        let sourceType = sourceType
        let localFileURL = localFileURL
        let sourceURLString = sourceURLString
        let quality = quality
        let outputRootURL = outputRootURL
        let installDependencies = installDependencies

        extractionTask?.cancel()
        extractionTask = Task {
            do {
                let result = try await service.extract(
                    sourceType: sourceType,
                    localFileURL: localFileURL,
                    sourceURLString: sourceURLString,
                    quality: quality,
                    outputRootURL: outputRootURL,
                    installDeps: installDependencies,
                    onLog: { [weak self] text in
                        Task { @MainActor in
                            self?.appendLog(text)
                        }
                    }
                )
                latestOutputDirectoryURL = result.outputDirectory
                latestMP3URL = result.mp3URL
                statusMessage = L10n.f("audio.extract.status.done", result.mp3URL.lastPathComponent)
                appendLog("[done] \(statusMessage)")
            } catch is CancellationError {
                statusMessage = L10n.tr("audio.extract.status.cancelled")
                appendLog("[stop] \(statusMessage)")
            } catch let error as AudioExtractServiceError {
                statusMessage = error.errorDescription ?? L10n.tr("audio.extract.error.output_validation")
                appendLog("[error] \(statusMessage)")
            } catch {
                statusMessage = error.localizedDescription
                appendLog("[error] \(statusMessage)")
            }
            isExtracting = false
            extractionTask = nil
        }
    }

    func stopExtraction() {
        guard isExtracting else { return }
        extractionTask?.cancel()
        extractionTask = nil
        service.stopCurrentTask()
        isExtracting = false
        statusMessage = L10n.tr("audio.extract.status.cancelled")
        appendLog("[stop] \(statusMessage)")
    }

    func openOutputDirectory() {
        guard let url = latestOutputDirectoryURL else {
            statusMessage = L10n.tr("audio.extract.status.no_output_yet")
            appendLog("[output] \(statusMessage)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLatestMP3() {
        guard let url = latestMP3URL else {
            statusMessage = L10n.tr("audio.extract.status.no_output_yet")
            appendLog("[output] \(statusMessage)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logs.append(trimmed)
        if logs.count > 400 {
            logs.removeFirst(logs.count - 400)
        }
    }
}
