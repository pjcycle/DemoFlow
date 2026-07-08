//
//  AudioTranscodeViewModel.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AudioTranscodeViewModel: ObservableObject {
    @Published var draft = AudioTranscodeDraft()
    @Published var jobs: [AudioTranscodeJob] = []
    @Published var isDropTargeted = false
    @Published private(set) var isConverting = false
    @Published private(set) var statusMessage: String = L10n.tr("audio.transcode.status.idle")

    private let importService = AudioImportService()
    private let service = AudioTranscodeService()
    private var conversionTask: Task<Void, Never>?

    var supportedTypes: [UTType] {
        importService.supportedTypes
    }

    var outputFormats: [AudioTranscodeOutputFormat] {
        AudioTranscodeOutputFormat.allCases
    }

    var qualityPresets: [AudioTranscodeQualityPreset] {
        AudioTranscodeQualityPreset.allCases
    }

    var selectedJob: AudioTranscodeJob? {
        if let selectedJobID = draft.selectedJobID,
           let job = jobs.first(where: { $0.id == selectedJobID }) {
            return job
        }
        return jobs.first
    }

    var canConvertSelected: Bool {
        selectedJob != nil && !isConverting
    }

    var canConvertAll: Bool {
        !jobs.isEmpty && !isConverting
    }

    var canStop: Bool {
        isConverting
    }

    var canReset: Bool {
        !jobs.isEmpty && !isConverting
    }

    var shouldShowQualityPreset: Bool {
        draft.outputFormat.supportsQualityPreset
    }

    var hasSuccessfulOutput: Bool {
        jobs.contains(where: { $0.result != nil })
    }

    func presentImporter() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedTypes
        panel.prompt = L10n.tr("audio.import.action.choose_files")
        let response = panel.runModal()
        guard response == .OK else {
            statusMessage = L10n.tr("audio.import.status.cancelled")
            return
        }
        importAudioFiles(from: panel.urls)
    }

    func importAudioFiles(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        statusMessage = L10n.tr("audio.import.status.loading")

        Task { @MainActor [weak self] in
            guard let self else { return }
            var imported: [AudioTranscodeJob] = []
            var firstError: String?

            for url in urls {
                do {
                    let prepared = try await importService.prepareAudio(from: url)
                    imported.append(AudioTranscodeJob(preparedAsset: prepared))
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }

            if !imported.isEmpty {
                jobs.append(contentsOf: imported)
                if draft.selectedJobID == nil {
                    draft.selectedJobID = imported.first?.id
                }
                statusMessage = L10n.f("audio.transcode.status.imported_count", imported.count)
            } else {
                statusMessage = firstError ?? L10n.tr("audio.import.error.unsupported")
            }
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let matchingProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matchingProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in matchingProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
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

                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.importAudioFiles(from: urls)
        }
        return true
    }

    func selectJob(id: UUID) {
        draft.selectedJobID = id
    }

    func setOutputFormat(_ format: AudioTranscodeOutputFormat) {
        draft.outputFormat = format
    }

    func setQualityPreset(_ preset: AudioTranscodeQualityPreset) {
        draft.qualityPreset = preset
    }

    func convertSelected() {
        guard let job = selectedJob else { return }
        convert(jobIDs: [job.id])
    }

    func convertAll() {
        convert(jobIDs: jobs.map(\.id))
    }

    func stopConversion() {
        guard isConverting else { return }
        conversionTask?.cancel()
        service.stopCurrentTask()
        statusMessage = L10n.tr("audio.transcode.status.cancelling")
    }

    func resetJobs() {
        guard !isConverting else { return }
        jobs.removeAll()
        draft.selectedJobID = nil
        statusMessage = L10n.tr("audio.transcode.status.idle")
    }

    private func convert(jobIDs: [UUID]) {
        guard !jobIDs.isEmpty else { return }

        let lockedDraft = draft
        isConverting = true
        statusMessage = L10n.tr("audio.transcode.status.preparing")

        conversionTask?.cancel()
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isConverting = false
                conversionTask = nil
            }

            var succeededCount = 0
            var failedCount = 0

            for jobID in jobIDs {
                if Task.isCancelled {
                    statusMessage = L10n.tr("audio.transcode.status.cancelled")
                    break
                }
                guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                let preparedAsset = jobs[index].preparedAsset

                jobs[index].status = .converting
                jobs[index].errorMessage = nil
                statusMessage = L10n.f("audio.transcode.status.converting_named", preparedAsset.displayName)

                guard let outputURL = requestOutputURL(for: preparedAsset, format: lockedDraft.outputFormat) else {
                    jobs[index].status = .failed
                    jobs[index].errorMessage = L10n.tr("audio.transcode.error.save_cancelled")
                    failedCount += 1
                    continue
                }

                do {
                    let result = try await service.convert(
                        sourceURL: preparedAsset.sourceURL,
                        outputFormat: lockedDraft.outputFormat,
                        quality: lockedDraft.qualityPreset,
                        outputURL: outputURL,
                        onLog: { _ in }
                    )
                    jobs[index].status = .succeeded
                    jobs[index].result = result
                    succeededCount += 1
                } catch is CancellationError {
                    jobs[index].status = .failed
                    jobs[index].errorMessage = L10n.tr("audio.transcode.status.cancelled")
                    failedCount += 1
                    statusMessage = L10n.tr("audio.transcode.status.cancelled")
                    break
                } catch let error as AudioTranscodeError {
                    jobs[index].status = .failed
                    jobs[index].errorMessage = error.errorDescription
                    failedCount += 1
                } catch {
                    jobs[index].status = .failed
                    jobs[index].errorMessage = error.localizedDescription
                    failedCount += 1
                }
            }

            if Task.isCancelled {
                statusMessage = L10n.tr("audio.transcode.status.cancelled")
            } else {
                statusMessage = L10n.f("audio.transcode.status.done_counts", succeededCount, failedCount)
            }
        }
    }

    private func requestOutputURL(for asset: AudioPreparedAsset, format: AudioTranscodeOutputFormat) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = format.suggestedContentType.map { [$0] } ?? []
        panel.directoryURL = DemoFlowOutputDirectoryPolicy.audioOutputDirectoryBookmarkedURL()
        panel.nameFieldStringValue = "\(asset.displayName)_converted.\(format.fileExtension)"
        panel.prompt = L10n.tr("audio.export.action.save")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }
}
