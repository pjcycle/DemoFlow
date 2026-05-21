//
//  VideoCuttingViewModel.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import AVFoundation
import Combine
import CoreMedia
import Foundation
import UniformTypeIdentifiers

@MainActor
final class VideoCuttingViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var sourceDuration: Double = 0
    @Published var keepStartText: String = "0"
    @Published var keepEndText: String = "10"
    @Published var deleteRanges: [CutRange] = []
    @Published var selectedDeleteRangeID: UUID?
    @Published var statusMessage: String = L10n.tr("legacy.key_202")
    @Published var isExporting = false
    @Published var exportURL: URL?
    @Published var selectedAspectPreset: VideoCuttingAspectPreset = .adaptive
    @Published var playbackPosition: Double = 0
    @Published var isPlaying = false
    @Published var hasPlaybackReady = false
    @Published private(set) var videoFPS: Double = 30
    @Published private(set) var frameDurationSeconds: Double = 1.0 / 30.0
    @Published private(set) var sourceVideoSize: CGSize = .zero
    @Published private(set) var sourceVideoAspect: Double = 16.0 / 9.0
    @Published var cropRectNormalized: VideoCropRect = .full
    @Published var isApplyingCrop = false
    @Published var isNoiseReductionEnabled = false
    @Published var noiseReductionPercent: Double = 50
    @Published var selectedAudioEQPreset: VideoCuttingAudioEQPreset = .balanced
    @Published private(set) var hasAudioTrack = false
    @Published private(set) var isApplyingAudioPreview = false
    @Published private(set) var isPreparingFFmpeg = false
    @Published private(set) var isFFmpegReady = false
    @Published private(set) var isUsingBuiltinComposeFallback = false
    @Published private(set) var ffmpegStatusMessage: String = ""

    private let trimEngine: TrimExportEngine
    private let composeExportEngine = VideoCuttingComposeExportEngine()
    private let ffmpegExportEngine = VideoCuttingFFmpegExportEngine()
    private let audioProcessingEngine = VideoCuttingAudioProcessingEngine()
    private let importService = VideoCuttingImportService()
    private let importPanelService = VideoCuttingImportPanelService()
    private let trimService = VideoCuttingTrimService()
    private let exportService = VideoCuttingExportService()
    private var cancellables: Set<AnyCancellable> = []
    private var timeObserverToken: Any?
    private let defaultFPS: Double = 30
    private let minimumFrameDuration: Double = 1.0 / 120.0
    private let maximumFrameDuration: Double = 1.0
    private let cropMinPoints = CGSize(width: 120, height: 120)
    let player = AVPlayer()
    let noiseReductionStep: Double = 10

    init(trimEngine: TrimExportEngine? = nil) {
        self.trimEngine = trimEngine ?? TrimExportEngine()
        configurePlayerObservers()
        configurePlayerStateObservers()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    var canExport: Bool {
        sourceURL != nil && !isBusy && sourceDuration > 0
    }

    var canDeleteSelectedRangeAndReload: Bool {
        guard sourceURL != nil, !isBusy, sourceDuration > 0, let selectedDeleteRange else { return false }
        let normalized = normalizeDeleteRanges([selectedDeleteRange])
        guard !normalized.isEmpty else { return false }
        let keepRanges = trimEngine.keepRanges(from: normalized, sourceDuration: makeDurationTime())
        return !keepRanges.isEmpty
    }

    var canApplyAllDeleteRangesAndReload: Bool {
        guard sourceURL != nil, !isBusy, sourceDuration > 0 else { return false }
        let normalized = normalizeDeleteRanges(deleteRanges)
        guard !normalized.isEmpty else { return false }
        let keepRanges = trimEngine.keepRanges(from: normalized, sourceDuration: makeDurationTime())
        return !keepRanges.isEmpty
    }

    var canExecuteCrop: Bool {
        guard sourceURL != nil, !isBusy, sourceDuration > 0 else { return false }
        let crop = normalizedCropRect
        guard crop.width > 0, crop.height > 0 else { return false }
        return !isCropNoOp
    }

    var isBusy: Bool {
        isExporting || isApplyingCrop || isPreparingFFmpeg
    }

    var audioProcessingConfig: VideoCuttingAudioProcessingConfig {
        VideoCuttingAudioProcessingConfig(
            noiseReductionEnabled: isNoiseReductionEnabled,
            noiseReductionPercent: noiseReductionPercent,
            eqPreset: selectedAudioEQPreset
        ).clamped
    }

    var hasSource: Bool {
        sourceURL != nil
    }

    var ffmpegPermissionStateText: String {
        if isPreparingFFmpeg {
            return L10n.tr("ffmpeg.permission.status.preparing")
        }
        if isUsingBuiltinComposeFallback {
            return L10n.tr("ffmpeg.permission.status.fallback")
        }
        return isFFmpegReady
            ? L10n.tr("ffmpeg.permission.status.ready")
            : L10n.tr("ffmpeg.permission.status.not_ready")
    }

    var selectedDeleteRange: CutRange? {
        guard let selectedDeleteRangeID else { return nil }
        return deleteRanges.first { $0.id == selectedDeleteRangeID }
    }

    var allowedImportTypes: [UTType] {
        importService.allowedTypes
    }

    var isCropNoOp: Bool {
        let crop = normalizedCropRect
        let full = abs(crop.minX) <= 0.0005 &&
            abs(crop.minY) <= 0.0005 &&
            abs(crop.width - 1) <= 0.0005 &&
            abs(crop.height - 1) <= 0.0005
        return full && normalizeDeleteRanges(deleteRanges).isEmpty
    }

    func importByPanel() {
        guard let selectedURL = importPanelService.pickSourceURL() else {
            statusMessage = L10n.tr("legacy.key_84")
            return
        }
        do {
            let persisted = try importService.persistImportedVideo(from: selectedURL)
            loadVideo(url: persisted)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func requestFFmpegPermissionFromMenu() {
        guard !isPreparingFFmpeg else { return }
        Task {
            await prepareFFmpegIfNeeded(force: true)
            if isFFmpegReady {
                statusMessage = L10n.tr("ffmpeg.permission.request.success")
            } else if isUsingBuiltinComposeFallback {
                statusMessage = L10n.tr("ffmpeg.permission.request.fallback")
            } else {
                statusMessage = L10n.f(
                    "fmt.ffmpeg.permission_request_failed",
                    L10n.tr("ffmpeg.permission.status.not_ready")
                )
            }
        }
    }

    func handleDrop(providers: [NSItemProvider]) {
        importService.resolveDroppedProviders(providers) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(url):
                self.loadVideo(url: url)
            case let .failure(error):
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func applyQuickKeepRangeInput() {
        guard hasSource else {
            statusMessage = L10n.tr("legacy.key_201")
            return
        }

        guard let start = Double(keepStartText), let end = Double(keepEndText) else {
            statusMessage = L10n.tr("legacy.key_11")
            return
        }

        let snappedStart = snapToFrame(start)
        let snappedEnd = snapToFrame(end)
        let lower = min(snappedStart, snappedEnd)
        let upper = max(snappedStart, snappedEnd)

        guard upper > lower else {
            statusMessage = L10n.tr("legacy.key_10")
            return
        }

        var ranges: [CutRange] = []
        if lower > 0 {
            ranges.append(makeCutRange(start: 0, end: lower))
        }
        if upper < sourceDuration {
            ranges.append(makeCutRange(start: upper, end: sourceDuration))
        }

        keepStartText = formatSecondsForInput(lower)
        keepEndText = formatSecondsForInput(upper)
        applyDeleteRangeEdit(ranges, preferSelection: nil, editMessage: L10n.tr("legacy.key_87"))
    }

    func addDeleteRangeAtPlayhead() {
        guard hasSource else {
            statusMessage = L10n.tr("legacy.key_201")
            return
        }
        let start = snapToFrame(playbackPosition)
        let defaultLength = max(5.0, frameDurationSeconds)
        let end = snapToFrame(min(sourceDuration, start + defaultLength))
        guard end > start else {
            statusMessage = L10n.tr("legacy.key_150")
            return
        }
        var updated = deleteRanges
        let range = makeCutRange(start: start, end: end)
        updated.append(range)
        applyDeleteRangeEdit(updated, preferSelection: range.id, editMessage: L10n.tr("legacy.key_91"))
    }

    func suggestedDeleteRangeInput(defaultLength: Double = 5.0) -> (start: String, end: String) {
        guard hasSource else {
            return (keepStartText, keepEndText)
        }

        let start = snapToFrame(playbackPosition)
        let length = max(defaultLength, frameDurationSeconds)
        let end = snapToFrame(min(sourceDuration, start + length))
        let safeEnd = end > start ? end : min(sourceDuration, start + length)
        return (formatSecondsForInput(start), formatSecondsForInput(safeEnd))
    }

    func addDeleteRangeByInput() {
        addDeleteRange(startText: keepStartText, endText: keepEndText)
    }

    func addDeleteRange(startText: String, endText: String) {
        guard hasSource else {
            statusMessage = L10n.tr("legacy.key_201")
            return
        }

        guard let start = Double(startText), let end = Double(endText) else {
            statusMessage = L10n.tr("legacy.key_11")
            return
        }
        addDeleteRange(start: start, end: end)
    }

    func addDeleteRange(start: Double, end: Double) {
        guard hasSource else {
            statusMessage = L10n.tr("legacy.key_201")
            return
        }
        let snappedStart = snapToFrame(start)
        let snappedEnd = snapToFrame(end)
        let lower = min(snappedStart, snappedEnd)
        let upper = max(snappedStart, snappedEnd)

        guard upper > lower else {
            statusMessage = L10n.tr("legacy.key_10")
            return
        }

        let range = makeCutRange(start: lower, end: upper)
        var updated = deleteRanges
        updated.append(range)
        keepStartText = formatSecondsForInput(lower)
        keepEndText = formatSecondsForInput(upper)
        applyDeleteRangeEdit(updated, preferSelection: range.id, editMessage: L10n.tr("legacy.key_91"))
    }

    func updateDeleteRange(id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let index = deleteRanges.firstIndex(where: { $0.id == id }) else { return }
        var range = deleteRanges[index]
        if let start {
            range.start = makeTime(snapToFrame(start))
        }
        if let end {
            range.end = makeTime(snapToFrame(end))
        }
        var updated = deleteRanges
        updated[index] = range
        applyDeleteRangeEdit(updated, preferSelection: id)
    }

    func removeDeleteRange(id: UUID) {
        let updated = deleteRanges.filter { $0.id != id }
        applyDeleteRangeEdit(updated, preferSelection: selectedDeleteRangeID, editMessage: L10n.tr("legacy.key_83"))
    }

    func removeSelectedDeleteRange() {
        guard let selectedDeleteRangeID else { return }
        removeDeleteRange(id: selectedDeleteRangeID)
    }

    func deleteSelectedRangeAndReload() {
        guard let sourceURL else {
            statusMessage = L10n.tr("legacy.key_26")
            return
        }
        guard let selectedDeleteRange else {
            statusMessage = L10n.tr("legacy.key_27")
            return
        }

        let normalized = normalizeDeleteRanges([selectedDeleteRange])
        guard let selectedRange = normalized.first else {
            statusMessage = L10n.tr("legacy.key_28")
            return
        }

        let sourceDuration = makeDurationTime()
        let keepRanges = trimEngine.keepRanges(from: [selectedRange], sourceDuration: sourceDuration)
        guard !keepRanges.isEmpty else {
            statusMessage = L10n.tr("legacy.key_29")
            return
        }

        let outputURL: URL
        do {
            outputURL = try makeInlineTrimOutputURL(for: sourceURL, suffix: "cut")
        } catch {
            statusMessage = L10n.tr("legacy.key_25")
            return
        }

        isExporting = true
        statusMessage = L10n.tr("legacy.key_170")
        Task {
            defer { isExporting = false }
            do {
                let exported = try await runFFmpegExport(
                    sourceURL: sourceURL,
                    keepRanges: keepRanges,
                    cropRectNormalized: .full,
                    outputURL: outputURL,
                    applyAudioProcessing: false,
                    performanceProfile: .balanced
                )
                loadVideo(url: exported)
                cleanupInlineEditArtifacts(previousSourceURL: sourceURL, keeping: exported)
                statusMessage = L10n.f("fmt.video.delete_selected_reloaded", exported.lastPathComponent)
            } catch {
                statusMessage = L10n.f("fmt.video.delete_failed", error.localizedDescription)
            }
        }
    }

    func applyAllDeleteRangesAndReload() {
        guard let sourceURL else {
            statusMessage = L10n.tr("legacy.key_26")
            return
        }

        let normalized = normalizeDeleteRanges(deleteRanges)
        guard !normalized.isEmpty else {
            statusMessage = L10n.tr("legacy.key_27")
            return
        }

        let keepRanges = trimEngine.keepRanges(from: normalized, sourceDuration: makeDurationTime())
        guard !keepRanges.isEmpty else {
            statusMessage = L10n.tr("legacy.key_153")
            return
        }

        let outputURL: URL
        do {
            outputURL = try makeInlineTrimOutputURL(for: sourceURL, suffix: "cutall")
        } catch {
            statusMessage = L10n.tr("legacy.key_25")
            return
        }

        isExporting = true
        statusMessage = L10n.tr("legacy.key_170")
        Task {
            defer { isExporting = false }
            do {
                let exported = try await runFFmpegExport(
                    sourceURL: sourceURL,
                    keepRanges: keepRanges,
                    cropRectNormalized: .full,
                    outputURL: outputURL,
                    applyAudioProcessing: false,
                    performanceProfile: .balanced
                )
                loadVideo(url: exported)
                cleanupInlineEditArtifacts(previousSourceURL: sourceURL, keeping: exported)
                statusMessage = L10n.f("fmt.video.delete_selected_reloaded", exported.lastPathComponent)
            } catch {
                statusMessage = L10n.f("fmt.video.delete_failed", error.localizedDescription)
            }
        }
    }

    func selectDeleteRange(id: UUID?) {
        selectedDeleteRangeID = id
    }

    func deleteRangeStartSeconds(for id: UUID) -> Double {
        guard let range = deleteRanges.first(where: { $0.id == id }) else { return 0 }
        return clampedSeconds(range.normalized.start.seconds)
    }

    func deleteRangeEndSeconds(for id: UUID) -> Double {
        guard let range = deleteRanges.first(where: { $0.id == id }) else { return 0 }
        return clampedSeconds(range.normalized.end.seconds)
    }

    func exportTrimmedVideo() {
        guard let sourceURL else {
            statusMessage = L10n.tr("legacy.key_62")
            return
        }

        guard let outputURL = exportService.pickOutputURL(suggestedName: suggestedOutputName(for: sourceURL)) else {
            statusMessage = L10n.tr("legacy.key_85")
            return
        }

        isExporting = true
        if hasAudioTrack {
            statusMessage = L10n.tr("legacy.key_56")
        } else {
            statusMessage = L10n.tr("legacy.key_57")
        }
        Task {
            defer { isExporting = false }
            do {
                let exported = try await runFFmpegExport(
                    sourceURL: sourceURL,
                    keepRanges: [CMTimeRange(start: .zero, duration: makeDurationTime())],
                    cropRectNormalized: .full,
                    outputURL: outputURL,
                    applyAudioProcessing: true,
                    performanceProfile: .quality
                )
                exportURL = exported
                let removedTempFiles = cleanupHistoricalTemporaryFilesAfterExport(
                    keeping: [sourceURL, exported]
                )
                if removedTempFiles > 0 {
                    statusMessage = L10n.f(
                        "fmt.video.export_done_with_cleanup",
                        exported.lastPathComponent,
                        removedTempFiles
                    )
                } else {
                    statusMessage = L10n.f("fmt.video.export_done", exported.lastPathComponent)
                }
            } catch {
                statusMessage = L10n.f("fmt.video.export_failed", error.localizedDescription)
            }
        }
    }

    func revealExport() {
        guard let exportURL else { return }
        exportService.revealInFinder(exportURL)
    }

    func updateNoiseReductionEnabled(_ isEnabled: Bool) {
        isNoiseReductionEnabled = isEnabled
        applyAudioPreviewProcessing()
    }

    func updateNoiseReductionPercent(_ percent: Double) {
        let clamped = max(0, min(100, percent))
        let snapped = (clamped / noiseReductionStep).rounded() * noiseReductionStep
        noiseReductionPercent = max(0, min(100, snapped))
        applyAudioPreviewProcessing()
    }

    func updateAudioEQPreset(_ preset: VideoCuttingAudioEQPreset) {
        selectedAudioEQPreset = preset
        applyAudioPreviewProcessing()
    }

    func applyAudioPreviewProcessing() {
        guard hasSource else { return }
        guard hasAudioTrack else { return }
        guard let sourceURL else { return }

        isApplyingAudioPreview = true
        defer { isApplyingAudioPreview = false }

        Task {
            let asset = AVAssetAsyncLoaders.makeURLAsset(sourceURL)
            let item = await makePlayerItem(for: asset)
            await MainActor.run {
                self.player.replaceCurrentItem(with: item)
                let seekTime = self.makeTime(self.playbackPosition)
                self.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.isPlaying {
                    self.player.play()
                } else {
                    self.player.pause()
                }
            }
        }
    }

    func executeCropAndReload() {
        guard let sourceURL else {
            statusMessage = L10n.tr("legacy.key_129")
            return
        }
        guard canExecuteCrop else {
            statusMessage = isCropNoOp ? L10n.tr("legacy.key_104") : L10n.tr("legacy.key_128")
            return
        }

        let outputURL: URL
        do {
            outputURL = try makeInlineTrimOutputURL(for: sourceURL, suffix: "crop")
        } catch {
            statusMessage = L10n.tr("legacy.key_127")
            return
        }

        let normalizedDeleteRanges = normalizeDeleteRanges(deleteRanges)
        let keepRanges = trimEngine.keepRanges(from: normalizedDeleteRanges, sourceDuration: makeDurationTime())
        guard !keepRanges.isEmpty else {
            statusMessage = L10n.tr("legacy.key_153")
            return
        }

        isApplyingCrop = true
        statusMessage = L10n.tr("legacy.key_88")
        Task {
            defer { isApplyingCrop = false }
            do {
                let exported = try await runFFmpegExport(
                    sourceURL: sourceURL,
                    keepRanges: keepRanges,
                    cropRectNormalized: VideoCropRect(normalizedCropRect),
                    outputURL: outputURL,
                    applyAudioProcessing: false,
                    performanceProfile: .balanced
                )
                loadVideo(url: exported)
                cleanupInlineEditArtifacts(previousSourceURL: sourceURL, keeping: exported)
                statusMessage = L10n.f("fmt.video.crop_reloaded", exported.lastPathComponent)
            } catch {
                statusMessage = L10n.f("fmt.video.crop_failed", error.localizedDescription)
            }
        }
    }

    func resetCropRect(showStatus: Bool = true) {
        guard hasSource else { return }
        cropRectNormalized = .full
        if showStatus {
            statusMessage = L10n.tr("legacy.key_94")
        }
    }

    func selectAspectPresetWithReset(_ preset: VideoCuttingAspectPreset) {
        guard hasSource else {
            selectedAspectPreset = preset
            return
        }
        selectedAspectPreset = preset
        // Prevent prior drag state from affecting new aspect interaction.
        resetCropRect(showStatus: false)
        applyPresetToCropRect()
    }

    func applyPresetToCropRect() {
        guard hasSource else { return }
        let minSize = normalizedCropMinSize(for: sourceVideoSize)
        let adjusted = VideoCropGeometry.adjustedRectForAspect(
            rect: normalizedCropRect,
            targetRatio: selectedAspectPreset.widthOverHeightRatio,
            minSize: minSize
        )
        cropRectNormalized = VideoCropRect(adjusted)
    }

    func updateCropRectByDrag(
        handle: VideoCropHandle,
        translation: CGSize,
        overlayVideoDisplaySize: CGSize
    ) {
        guard hasSource else { return }
        let minSize = normalizedCropMinSize(for: overlayVideoDisplaySize)
        let next = VideoCropGeometry.applyDrag(
            startRect: normalizedCropRect,
            translation: translation,
            handle: handle,
            displaySize: overlayVideoDisplaySize,
            lockedAspectRatio: selectedAspectPreset.widthOverHeightRatio,
            minSize: minSize
        )
        cropRectNormalized = VideoCropRect(next)
    }

    func togglePlayPause() {
        guard hasSource else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func pausePlayback() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let bounded = clampedSeconds(seconds)
        let time = makeTime(bounded)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playbackPosition = bounded
    }

    func scrub(to seconds: Double) {
        seek(to: seconds)
    }

    func snapToFrame(_ seconds: Double) -> Double {
        let clamped = clampedSeconds(seconds)
        let frame = normalizedFrameDuration
        guard frame > 0 else { return clamped }
        let snapped = (clamped / frame).rounded() * frame
        let final = clampedSeconds(snapped)
        if sourceDuration > 0, sourceDuration - final <= frame / 2 {
            return sourceDuration
        }
        return final
    }

    func normalizeDeleteRanges(_ ranges: [CutRange]) -> [CutRange] {
        let snapped = ranges
            .map(\.normalized)
            .compactMap { range -> CutRange? in
                let start = snapToFrame(range.start.seconds)
                let end = snapToFrame(range.end.seconds)
                guard end > start else { return nil }
                return CutRange(id: range.id, start: makeTime(start), end: makeTime(end))
            }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    return lhs.end < rhs.end
                }
                return lhs.start < rhs.start
            }

        guard var current = snapped.first else { return [] }
        var merged: [CutRange] = []
        let mergeTolerance = normalizedFrameDuration + 0.000_1

        for range in snapped.dropFirst() {
            let currentEnd = clampedSeconds(current.end.seconds)
            let nextStart = clampedSeconds(range.start.seconds)
            if nextStart <= currentEnd + mergeTolerance {
                let newEnd = max(currentEnd, clampedSeconds(range.end.seconds))
                current.end = makeTime(newEnd)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    var totalDurationText: String {
        formatTime(sourceDuration)
    }

    var currentTimeText: String {
        formatTime(playbackPosition)
    }

    private var normalizedCropRect: CGRect {
        VideoCropGeometry.clampNormalizedRect(cropRectNormalized.cgRect)
    }

    private func loadVideo(url: URL) {
        guard importService.isSupportedVideo(url: url) else {
            statusMessage = L10n.tr("legacy.mp4_mov")
            return
        }
        Task {
            let asset = AVAssetAsyncLoaders.makeURLAsset(url)
            do {
                let duration = max(0, try await AVAssetAsyncLoaders.duration(of: asset).seconds)
                guard duration > 0 else {
                    await MainActor.run {
                        self.statusMessage = L10n.tr("legacy.key_51")
                    }
                    return
                }

                let hasAudioTrack = await updateFrameInfo(from: asset)
                let item = await makePlayerItem(for: asset)

                await MainActor.run {
                    self.sourceURL = url
                    self.sourceDuration = duration
                    self.keepStartText = self.formatSecondsForInput(0)
                    self.keepEndText = self.formatSecondsForInput(duration)
                    self.deleteRanges = []
                    self.selectedDeleteRangeID = nil
                    self.cropRectNormalized = .full
                    self.exportURL = nil
                    self.playbackPosition = 0
                    self.hasPlaybackReady = true
                    self.hasAudioTrack = hasAudioTrack
                    self.player.pause()
                    self.player.replaceCurrentItem(with: item)
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.isPlaying = false
                    if hasAudioTrack {
                        self.statusMessage = L10n.f("fmt.video.imported", url.lastPathComponent)
                    } else {
                        self.statusMessage = L10n.f("fmt.video.imported_no_audio_track", url.lastPathComponent)
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = L10n.f("fmt.video.import_failed", error.localizedDescription)
                }
            }
        }
    }

    private func applyDeleteRangeEdit(_ ranges: [CutRange], preferSelection: UUID?, editMessage: String? = nil) {
        let normalized = normalizeDeleteRanges(ranges)
        deleteRanges = normalized
        resolveSelection(preferSelection: preferSelection)

        let keepRanges = trimEngine.keepRanges(from: normalized, sourceDuration: makeDurationTime())
        if keepRanges.isEmpty {
            statusMessage = L10n.tr("legacy.key_153")
            return
        }

        if normalized.isEmpty {
            statusMessage = L10n.tr("legacy.key_105")
            return
        }

        if let editMessage {
            statusMessage = L10n.f("fmt.video.edit_message_with_delete_count", editMessage, normalized.count)
        } else {
            statusMessage = L10n.f("fmt.video.delete_ranges_updated", normalized.count)
        }
    }

    private func resolveSelection(preferSelection: UUID?) {
        if let preferSelection, deleteRanges.contains(where: { $0.id == preferSelection }) {
            selectedDeleteRangeID = preferSelection
            return
        }
        if let selectedDeleteRangeID, deleteRanges.contains(where: { $0.id == selectedDeleteRangeID }) {
            return
        }
        selectedDeleteRangeID = deleteRanges.first?.id
    }

    private func updateFrameInfo(from asset: AVAsset) async -> Bool {
        do {
            guard let track = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else {
                await MainActor.run {
                    self.videoFPS = self.defaultFPS
                    self.frameDurationSeconds = 1.0 / self.defaultFPS
                    self.sourceVideoSize = CGSize(width: 1920, height: 1080)
                    self.sourceVideoAspect = 16.0 / 9.0
                }
                let hasAudio = (try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio)) != nil
                return hasAudio
            }

            let nominal = Double(try await AVAssetAsyncLoaders.nominalFrameRate(of: track))
            let resolvedFPS: Double
            let resolvedFrameDuration: Double
            if nominal.isFinite, nominal > 0.1 {
                resolvedFPS = nominal
                resolvedFrameDuration = 1.0 / nominal
            } else {
                let minDuration = try await AVAssetAsyncLoaders.minFrameDuration(of: track).seconds
                if minDuration.isFinite, minDuration > 0 {
                    resolvedFrameDuration = minDuration
                    resolvedFPS = 1.0 / minDuration
                } else {
                    resolvedFPS = defaultFPS
                    resolvedFrameDuration = 1.0 / defaultFPS
                }
            }

            let size = try await AVAssetAsyncLoaders.orientedSize(of: track)
            let aspect: Double = (size.width > 1 && size.height > 1) ? Double(size.width / size.height) : (16.0 / 9.0)
            let hasAudio = (try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio)) != nil

            await MainActor.run {
                self.videoFPS = resolvedFPS
                self.frameDurationSeconds = resolvedFrameDuration
                self.sourceVideoSize = size
                self.sourceVideoAspect = aspect
            }
            return hasAudio
        } catch {
            await MainActor.run {
                self.videoFPS = self.defaultFPS
                self.frameDurationSeconds = 1.0 / self.defaultFPS
                self.sourceVideoSize = CGSize(width: 1920, height: 1080)
                self.sourceVideoAspect = 16.0 / 9.0
            }
            return false
        }
    }

    private func makeCutRange(start: Double, end: Double) -> CutRange {
        CutRange(start: makeTime(start), end: makeTime(end))
    }

    private func clampedSeconds(_ seconds: Double) -> Double {
        guard sourceDuration > 0 else { return max(0, seconds) }
        return max(0, min(seconds, sourceDuration))
    }

    private var normalizedFrameDuration: Double {
        let raw = frameDurationSeconds.isFinite && frameDurationSeconds > 0
            ? frameDurationSeconds
            : (1.0 / defaultFPS)
        return min(max(raw, minimumFrameDuration), maximumFrameDuration)
    }

    private func makeDurationTime() -> CMTime {
        makeTime(sourceDuration)
    }

    private func makeTime(_ seconds: Double) -> CMTime {
        let fpsTimescale = Int32((max(videoFPS, defaultFPS) * 1000).rounded())
        let timescale = max(CMTimeScale(600), CMTimeScale(fpsTimescale))
        return CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    private func formatSecondsForInput(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }

    private func suggestedOutputName(for sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return "\(stem)-trimmed.mp4"
    }

    private func makeInlineTrimOutputURL(for sourceURL: URL, suffix: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("VideoCuttingEdits", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let shortID = String(UUID().uuidString.prefix(8))
        return folder.appendingPathComponent("\(stem)-\(suffix)-\(shortID).mp4")
    }

    @discardableResult
    private func cleanupHistoricalTemporaryFilesAfterExport(keeping urls: [URL]) -> Int {
        let expirationInterval: TimeInterval = 3 * 24 * 60 * 60
        let now = Date()
        let keepPaths = Set(urls.map { $0.standardizedFileURL.path })
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
        let folders = [
            tempRoot.appendingPathComponent("VideoCuttingImports", isDirectory: true),
            tempRoot.appendingPathComponent("VideoCuttingEdits", isDirectory: true)
        ]

        var removedCount = 0
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in files {
                let normalized = fileURL.standardizedFileURL
                guard !keepPaths.contains(normalized.path) else { continue }
                guard shouldRemoveTemporaryFile(
                    at: normalized,
                    now: now,
                    expirationInterval: expirationInterval
                ) else {
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: normalized)
                    removedCount += 1
                } catch {
                    continue
                }
            }
        }
        return removedCount
    }

    private func shouldRemoveTemporaryFile(
        at fileURL: URL,
        now: Date,
        expirationInterval: TimeInterval
    ) -> Bool {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true else { return false }
        let modifiedAt = values?.contentModificationDate ?? .distantPast
        return now.timeIntervalSince(modifiedAt) >= expirationInterval
    }

    private func normalizedCropMinSize(for displaySize: CGSize) -> CGSize {
        VideoCropGeometry.normalizeMinSize(minPoints: cropMinPoints, videoDisplaySize: displaySize)
    }

    private func makePlayerItem(for asset: AVAsset) async -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        guard hasAudioTrack else { return item }
        guard let track = try? await AVAssetAsyncLoaders.firstTrack(in: item.asset, mediaType: .audio) else { return item }
        do {
            item.audioMix = try audioProcessingEngine.makeAudioMixIfNeeded(
                track: track,
                config: audioProcessingConfig
            )
        } catch {
            statusMessage = L10n.f("fmt.video.audio_preview_processing_failed", error.localizedDescription)
        }
        return item
    }

    private func runFFmpegExport(
        sourceURL: URL,
        keepRanges: [CMTimeRange],
        cropRectNormalized: VideoCropRect,
        outputURL: URL,
        applyAudioProcessing: Bool,
        performanceProfile: VideoCuttingFFmpegProject.PerformanceProfile
    ) async throws -> URL {
        await prepareFFmpegIfNeeded()
        if isFFmpegReady {
            let project = VideoCuttingFFmpegProject(
                sourceURL: sourceURL,
                keepRanges: keepRanges,
                cropRectNormalized: cropRectNormalized,
                audioProcessingConfig: applyAudioProcessing ? audioProcessingConfig : VideoCuttingAudioProcessingConfig(
                    noiseReductionEnabled: false,
                    noiseReductionPercent: 0,
                    eqPreset: .balanced
                ),
                outputURL: outputURL,
                hasAudioTrack: hasAudioTrack,
                performanceProfile: performanceProfile
            )
            do {
                return try await ffmpegExportEngine.export(project: project) { [weak self] ratio in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.ffmpegStatusMessage = L10n.f("fmt.ffmpeg.progress", Int((ratio * 100).rounded()))
                    }
                }
            } catch {
                self.isFFmpegReady = false
                self.isUsingBuiltinComposeFallback = true
                self.ffmpegStatusMessage = L10n.f("fmt.ffmpeg.fallback_active", error.localizedDescription)
            }
        }

        return try await runBuiltinComposeFallbackExport(
            sourceURL: sourceURL,
            keepRanges: keepRanges,
            cropRectNormalized: cropRectNormalized,
            outputURL: outputURL,
            applyAudioProcessing: applyAudioProcessing
        )
    }

    private func prepareFFmpegIfNeeded(force: Bool = false) async {
        if (isFFmpegReady || isUsingBuiltinComposeFallback), !force {
            return
        }
        isPreparingFFmpeg = true
        defer { isPreparingFFmpeg = false }
        do {
            try ffmpegExportEngine.ensureToolsReady()
            isFFmpegReady = true
            isUsingBuiltinComposeFallback = false
            ffmpegStatusMessage = L10n.tr("legacy.ffmpeg.ready")
        } catch {
            isFFmpegReady = false
            isUsingBuiltinComposeFallback = true
            ffmpegStatusMessage = L10n.f("fmt.ffmpeg.fallback_active", error.localizedDescription)
        }
    }

    private func runBuiltinComposeFallbackExport(
        sourceURL: URL,
        keepRanges: [CMTimeRange],
        cropRectNormalized: VideoCropRect,
        outputURL: URL,
        applyAudioProcessing: Bool
    ) async throws -> URL {
        let deleteRanges = deleteRangesFromKeepRanges(keepRanges, sourceDuration: sourceDuration)
        let composeProject = VideoCuttingComposeProject(
            sourceURL: sourceURL,
            deleteRanges: deleteRanges,
            cropRectNormalized: cropRectNormalized,
            targetAspectPreset: selectedAspectPreset,
            audioProcessingConfig: applyAudioProcessing
                ? audioProcessingConfig
                : VideoCuttingAudioProcessingConfig(
                    noiseReductionEnabled: false,
                    noiseReductionPercent: 0,
                    eqPreset: .balanced
                ),
            outputURL: outputURL
        )
        return try await composeExportEngine.export(project: composeProject)
    }

    private func cleanupInlineEditArtifacts(previousSourceURL: URL, keeping latestEditedURL: URL) {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .standardizedFileURL
        let keepPaths = Set([latestEditedURL.standardizedFileURL.path])
        let candidateFolders = [
            tempRoot.appendingPathComponent("VideoCuttingImports", isDirectory: true),
            tempRoot.appendingPathComponent("VideoCuttingEdits", isDirectory: true)
        ]

        for folder in candidateFolders {
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for fileURL in files {
                let normalized = fileURL.standardizedFileURL
                guard !keepPaths.contains(normalized.path) else { continue }
                let values = try? normalized.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                try? fm.removeItem(at: normalized)
            }
        }

        let previousNormalized = previousSourceURL.standardizedFileURL
        if previousNormalized.path.hasPrefix(tempRoot.path),
           !keepPaths.contains(previousNormalized.path) {
            try? fm.removeItem(at: previousNormalized)
        }
    }

    private func deleteRangesFromKeepRanges(_ keepRanges: [CMTimeRange], sourceDuration: Double) -> [CutRange] {
        let total = max(0, sourceDuration)
        guard total > 0 else { return [] }
        let normalized = keepRanges
            .compactMap { range -> (start: Double, end: Double)? in
                let rawStart = max(0, range.start.seconds)
                let rawEnd = max(rawStart, (range.start + range.duration).seconds)
                let start = min(total, rawStart)
                let end = min(total, rawEnd)
                guard end - start > 0.0005 else { return nil }
                return (start, end)
            }
            .sorted { $0.start < $1.start }

        guard !normalized.isEmpty else { return [CutRange(start: makeTime(0), end: makeTime(total))] }
        var merged: [(start: Double, end: Double)] = []
        for item in normalized {
            guard var last = merged.last else {
                merged.append(item)
                continue
            }
            if item.start <= last.end + 0.0005 {
                last.end = max(last.end, item.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(item)
            }
        }

        var cursor = 0.0
        var deletes: [CutRange] = []
        for item in merged {
            if item.start - cursor > 0.0005 {
                deletes.append(CutRange(start: makeTime(cursor), end: makeTime(item.start)))
            }
            cursor = max(cursor, item.end)
        }
        if total - cursor > 0.0005 {
            deletes.append(CutRange(start: makeTime(cursor), end: makeTime(total)))
        }
        return deletes
    }

    private func configurePlayerObservers() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = max(0, time.seconds)
                self.playbackPosition = min(seconds, self.sourceDuration)
            }
        }
    }

    private func configurePlayerStateObservers() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = (status == .playing)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isPlaying = false
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.playbackPosition = 0
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                self.isPlaying = false
                let message: String
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    message = error.localizedDescription
                } else {
                    message = L10n.tr("legacy.key_165")
                }
                self.statusMessage = L10n.f("fmt.video.playback_failed", message)
            }
            .store(in: &cancellables)
    }

    private func formatTime(_ seconds: Double) -> String {
        let safe = max(0, Int(seconds.rounded(.down)))
        let hours = safe / 3600
        let minutes = (safe % 3600) / 60
        let secs = safe % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
