//
//  AudioTrimViewModel.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AudioTrimViewModel: ObservableObject {
    @Published var draft = AudioTrimDraft()
    @Published var isDropTargeted = false
    @Published private(set) var previewStatus: AudioPreviewStatus = .idle
    @Published private(set) var statusMessage: String = L10n.tr("audio.trim.status.idle")

    private let importService = AudioImportService()
    private let waveformService = AudioWaveformService()
    private let previewService = AudioTrimPreviewService()
    private let trimEngine = AudioTrimEngine()
    private var previewAnchor: TimeInterval = 0
    private var isPreviewingSelection = false
    private var exportSucceeded = false

    var supportedTypes: [UTType] {
        importService.supportedTypes
    }

    var canPlay: Bool {
        draft.selectedPreparedAsset != nil
    }

    var canReset: Bool {
        draft.selectedPreparedAsset != nil
    }

    var canApplyTrimToEditor: Bool {
        guard let preparedAsset = draft.selectedPreparedAsset else { return false }
        return computeRemainingSegmentsAfterDeletingSelection(from: preparedAsset) != nil
    }

    var canExport: Bool {
        draft.selectedPreparedAsset != nil && draft.preferredOutputFormat != nil
    }

    var hasSuccessfulOutput: Bool {
        exportSucceeded
    }

    var exportAvailability: AudioTrimExportAvailability {
        trimEngine.exportAvailability(for: draft.preferredOutputFormat)
    }

    var selectedPreparedAsset: AudioPreparedAsset? {
        draft.selectedPreparedAsset
    }

    var playheadTimeText: String {
        formatTime(draft.playheadTime)
    }

    var totalOutputDurationText: String {
        draft.selectedPreparedAsset?.durationText ?? "00:00"
    }

    func presentImporter() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedTypes
        panel.prompt = L10n.tr("audio.import.action.choose_file")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            statusMessage = L10n.tr("audio.import.status.cancelled")
            return
        }
        importAudio(from: url)
    }

    func importAudio(from url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await loadAudio(url: url, preferredOutputFormat: nil)
                statusMessage = L10n.f("audio.trim.status.imported_named", draft.selectedPreparedAsset?.displayName ?? url.lastPathComponent)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let matchingProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard let provider = matchingProviders.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data {
                url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL
            } else if let directURL = item as? URL {
                url = directURL
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = nil
            }

            guard let url else { return }
            DispatchQueue.main.async {
                self?.importAudio(from: url)
            }
        }
        return true
    }

    func playPause() {
        switch previewStatus {
        case .playing:
            previewService.pause()
            previewStatus = .paused
            statusMessage = L10n.tr("audio.trim.status.paused")
        case .paused:
            previewService.resume()
            previewStatus = .playing
            statusMessage = L10n.tr("audio.trim.status.playing")
        case .idle, .failed:
            playCurrentPreview()
        }
    }

    func stopPlayback() {
        previewService.stop()
        previewStatus = .idle
        isPreviewingSelection = false
        previewAnchor = 0
        statusMessage = L10n.tr("audio.trim.status.idle")
    }

    func resetEditor() {
        stopPlayback()
        draft = AudioTrimDraft()
        exportSucceeded = false
        statusMessage = L10n.tr("audio.trim.status.idle")
    }

    func zoomIn() {
        draft.zoomLevel = min(draft.zoomLevel + 0.5, 8)
    }

    func zoomOut() {
        draft.zoomLevel = max(draft.zoomLevel - 0.5, 1)
    }

    func resetZoom() {
        draft.zoomLevel = 1
    }

    func setActiveRange(start: TimeInterval, end: TimeInterval) {
        let next = AudioTrimRange(startTime: min(start, end), endTime: max(start, end))
        draft.activeRange = next.duration > 0 ? next : nil
        if case .playing = previewStatus {
            stopPlayback()
        }
    }

    func clearActiveRange() {
        draft.activeRange = nil
        if case .playing = previewStatus {
            stopPlayback()
        }
    }

    func setPlayheadTime(_ time: TimeInterval) {
        guard let preparedAsset = draft.selectedPreparedAsset else { return }
        draft.playheadTime = min(max(time, 0), preparedAsset.duration)
    }

    func applyTrimToEditor() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let preparedAsset = draft.selectedPreparedAsset else {
                statusMessage = AudioTrimError.noSource.localizedDescription
                return
            }
            guard let remainingSegments = computeRemainingSegmentsAfterDeletingSelection(from: preparedAsset) else {
                statusMessage = AudioTrimError.tooShort.localizedDescription
                return
            }

            do {
                let nextBaseName = nextTrimmedBaseName()
                let workingCopyURL = try await trimEngine.makeWorkingCopyURL(
                    preparedAsset: preparedAsset,
                    remainingSegments: remainingSegments
                )
                let preferredOutputFormat = draft.preferredOutputFormat
                try await loadAudio(url: workingCopyURL, preferredOutputFormat: preferredOutputFormat, defaultExportName: nextBaseName)
                draft.exportFileName = nextBaseName
                statusMessage = L10n.tr("audio.trim.status.applied")
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func deleteSelectedRange() {
        applyTrimToEditor()
    }

    func exportTrimmedAudio() {
        guard let preparedAsset = draft.selectedPreparedAsset,
              let outputFormat = draft.preferredOutputFormat else {
            statusMessage = AudioTrimError.noSource.localizedDescription
            return
        }
        guard let outputURL = requestOutputURL(baseName: draft.exportFileName, format: outputFormat) else {
            statusMessage = L10n.tr("audio.trim.error.save_cancelled")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await trimEngine.exportCurrentAsset(
                    preparedAsset: preparedAsset,
                    outputFormat: outputFormat,
                    outputURL: outputURL,
                    onLog: { _ in }
                )
                exportSucceeded = true
                statusMessage = L10n.f("audio.trim.status.exported_named", result.outputURL.lastPathComponent)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func playCurrentPreview() {
        Task { @MainActor [weak self] in
            guard let self, let preparedAsset = draft.selectedPreparedAsset else { return }

            do {
                let previewURL: URL
                let startTime: TimeInterval
                let anchor: TimeInterval

                if let activeRange = draft.activeRange, activeRange.duration > 0 {
                    previewURL = try await trimEngine.makePreviewURL(preparedAsset: preparedAsset, range: activeRange)
                    anchor = activeRange.startTime
                    let relativeTime = max(draft.playheadTime - activeRange.startTime, 0)
                    startTime = min(relativeTime, activeRange.duration)
                    isPreviewingSelection = true
                } else {
                    previewURL = preparedAsset.sourceURL
                    anchor = 0
                    startTime = draft.playheadTime
                    isPreviewingSelection = false
                }

                previewAnchor = anchor
                try previewService.play(
                    url: previewURL,
                    startTime: startTime,
                    onProgress: { [weak self] currentTime in
                        guard let self else { return }
                        self.setPlayheadTime(self.previewAnchor + currentTime)
                    },
                    onFinish: { [weak self] in
                        guard let self else { return }
                        self.previewStatus = .idle
                        self.statusMessage = L10n.tr("audio.trim.status.idle")
                    }
                )
                previewStatus = .playing
                statusMessage = isPreviewingSelection ? L10n.tr("audio.trim.status.playing_selection") : L10n.tr("audio.trim.status.playing")
            } catch {
                previewStatus = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    private func computeRemainingSegmentsAfterDeletingSelection(from preparedAsset: AudioPreparedAsset) -> [AudioTrimSegment]? {
        guard let activeRange = draft.activeRange, activeRange.duration > 0 else { return nil }

        let start = min(max(activeRange.startTime, 0), preparedAsset.duration)
        let end = min(max(activeRange.endTime, 0), preparedAsset.duration)
        guard end > start else { return nil }

        var segments: [AudioTrimSegment] = []
        if start > 0 {
            segments.append(AudioTrimSegment(startTime: 0, endTime: start))
        }
        if end < preparedAsset.duration {
            segments.append(AudioTrimSegment(startTime: end, endTime: preparedAsset.duration))
        }

        let remainingDuration = segments.reduce(0) { $0 + $1.duration }
        guard remainingDuration >= 0.5 else { return nil }
        return segments
    }

    private func nextTrimmedBaseName() -> String {
        let trimmed = draft.exportFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? (draft.selectedPreparedAsset?.displayName ?? "trimmed_audio") : trimmed
        if seed.hasSuffix("_trimmed") {
            return seed
        }
        return "\(seed)_trimmed"
    }

    private func loadAudio(
        url: URL,
        preferredOutputFormat: AudioTranscodeOutputFormat?,
        defaultExportName: String? = nil
    ) async throws {
        stopPlayback()

        let preparedAsset = try await importService.prepareAudio(from: url)
        let waveformSamples: [CGFloat]
        do {
            waveformSamples = try await waveformService.loadWaveformSamples(from: url)
        } catch {
            waveformSamples = AudioWaveformService.placeholderSamples()
        }
        let outputFormat = preferredOutputFormat ?? defaultOutputFormat(for: url)

        draft.selectedPreparedAsset = preparedAsset
        draft.waveformSamples = waveformSamples
        draft.activeRange = nil
        draft.zoomLevel = 1
        draft.playheadTime = 0
        draft.preferredOutputFormat = outputFormat
        draft.originalFormatHint = preparedAsset.sourceFormatHint
        draft.exportFileName = defaultExportName ?? "\(preparedAsset.displayName)_trimmed"
        exportSucceeded = false
        previewStatus = .idle
        previewAnchor = 0
        isPreviewingSelection = false
    }

    private func defaultOutputFormat(for url: URL) -> AudioTranscodeOutputFormat {
        switch url.pathExtension.lowercased() {
        case "wav", "wave", "aiff", "aif":
            return .wav
        case "m4a", "aac":
            return .m4a
        case "flac":
            return .flac
        case "mp3":
            return .mp3
        default:
            return .m4a
        }
    }

    private func requestOutputURL(baseName: String, format: AudioTranscodeOutputFormat) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = format.suggestedContentType.map { [$0] } ?? []
        panel.directoryURL = DemoFlowOutputDirectoryPolicy.audioOutputDirectoryBookmarkedURL()
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        panel.prompt = L10n.tr("audio.export.action.save")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
