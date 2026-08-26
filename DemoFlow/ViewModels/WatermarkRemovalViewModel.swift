import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WatermarkRemovalViewModel: NSObject, ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var sourceVideoSize: CGSize = .zero
    @Published private(set) var sourceWaveformSamples: [Double] = []
    @Published private(set) var hasAudioTrack = false
    @Published private(set) var audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var isPlayerReady = false
    @Published private(set) var isPreviewPlaying = false
    @Published var regions: [WatermarkRegion] = []
    @Published var selectedRegionID: UUID?
    @Published var selectedQuality: VideoConversionQualityPreset = .balanced
    @Published var selectedRepairPreset: WatermarkRepairPreset = .balanced
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var state: WatermarkRemovalState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var canExportCurrentVideo = false
    @Published private(set) var isExportingCurrentVideo = false
    @Published private(set) var statusMessage = L10n.tr("subdub.watermark.status.idle")
    @Published private(set) var watermarkLibrary = WatermarkLibrarySnapshot()
    @Published var isWatermarkLibraryPresented = false

    let player = AVPlayer()

    var onProcessedVideoReady: ((URL) -> Void)?

    private let timelineSession: SubDubTimelineSession
    private let service = WatermarkRemovalService()
    private let workspace = SubDubWorkspaceService()
    private let libraryService = WatermarkLibraryService()
    private var sessionCancellable: AnyCancellable?
    private var activeTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var temporaryOutputURL: URL?
    private var preserveExportAvailabilityOnNextSourceChange = false
    private var sourceSessionDirectory: URL?
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?

    init(timelineSession: SubDubTimelineSession) {
        self.timelineSession = timelineSession
        super.init()
        sessionCancellable = timelineSession.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncFromSession()
                }
            }
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                playbackPosition = max(0, time.seconds)
                isPreviewPlaying = player.timeControlStatus == .playing
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as AnyObject? === player.currentItem else { return }
            Task { @MainActor [weak self] in self?.isPreviewPlaying = false }
        }
        reloadWatermarkLibrary()
        syncFromSession()
    }

    deinit {
        activeTask?.cancel()
        exportTask?.cancel()
        if let timeObserverToken { player.removeTimeObserver(timeObserverToken) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var hasSource: Bool { sourceURL != nil && sourceDuration > 0 && sourceVideoSize.width > 0 }
    var sourceName: String { sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video") }
    var playbackPositionText: String { "\(formatTime(playbackPosition)) / \(formatTime(sourceDuration))" }
    var canPreviewFrame: Bool { hasSource && !regions.isEmpty && !state.isBusy }
    var canProcess: Bool { canPreviewFrame }
    var watermarkLibraryAvailable: Bool { libraryService.isAvailable() }
    var selectedRegion: WatermarkRegion? {
        guard let selectedRegionID else { return nil }
        return regions.first(where: { $0.id == selectedRegionID })
    }

    var selectedRegionIndex: Int? {
        guard let selectedRegionID,
              let index = regions.firstIndex(where: { $0.id == selectedRegionID }) else { return nil }
        return index + 1
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        self.subscriptionViewModel = subscriptionViewModel
        self.onRequireSubscription = onRequireSubscription
    }

    func addRegion() {
        guard hasSource, !state.isBusy else { return }
        let region = WatermarkRegion(
            rectNormalized: VideoCropRect(x: 0.35, y: 0.35, width: 0.3, height: 0.18)
        )
        regions.append(region)
        selectedRegionID = region.id
        clearFramePreview()
        statusMessage = L10n.f("subdub.watermark.status.region_added", regions.count)
    }

    func selectRegion(_ id: UUID) {
        guard regions.contains(where: { $0.id == id }) else { return }
        selectedRegionID = id
    }

    func selectRegionAndOpenLibrary(_ id: UUID) {
        selectRegion(id)
        openWatermarkLibrary()
    }

    func openWatermarkLibrary() {
        guard !state.isBusy else { return }
        reloadWatermarkLibrary()
        isWatermarkLibraryPresented = true
    }

    func reloadWatermarkLibrary() {
        do {
            watermarkLibrary = try libraryService.load()
            refreshRegionReplacementsFromLibrary()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteSelectedRegion() {
        guard let selectedRegionID else { return }
        regions.removeAll { $0.id == selectedRegionID }
        self.selectedRegionID = regions.last?.id
        clearFramePreview()
        statusMessage = regions.isEmpty
            ? L10n.tr("subdub.watermark.status.regions_empty")
            : L10n.f("subdub.watermark.status.region_removed", regions.count)
    }

    func clearRegions() {
        guard !regions.isEmpty else { return }
        clearReplacementAssets()
        regions = []
        selectedRegionID = nil
        clearFramePreview()
        statusMessage = L10n.tr("subdub.watermark.status.regions_empty")
    }

    func updateRegion(
        id: UUID,
        startingRect: CGRect,
        handle: VideoCropHandle,
        translation: CGSize,
        displaySize: CGSize
    ) {
        guard let index = regions.firstIndex(where: { $0.id == id }), !state.isBusy else { return }
        let minSize = VideoCropGeometry.normalizeMinSize(
            minPoints: CGSize(width: 16, height: 16),
            videoDisplaySize: displaySize
        )
        let rect = VideoCropGeometry.applyDrag(
            startRect: startingRect,
            translation: translation,
            handle: handle,
            displaySize: displaySize,
            lockedNormalizedAspectRatio: nil,
            minSize: minSize
        )
        regions[index].rectNormalized = VideoCropRect(rect)
        clearFramePreview()
    }

    func importLibraryPNG() {
        guard !state.isBusy, let sourceURL = workspace.pickWatermarkPNGURL() else { return }
        var importedImage: WatermarkLibraryImage?
        do {
            let image = try libraryService.importPNG(from: sourceURL)
            importedImage = image
            var snapshot = watermarkLibrary
            snapshot.images.insert(image, at: 0)
            try libraryService.save(snapshot)
            watermarkLibrary = snapshot
            statusMessage = L10n.tr("subdub.watermark.library.image_added")
        } catch {
            if let importedImage {
                try? libraryService.deleteImage(importedImage)
            }
            statusMessage = error.localizedDescription
        }
    }

    func imageLibraryURL(for image: WatermarkLibraryImage) -> URL? {
        libraryService.imageURL(for: image)
    }

    func revealWatermarkLibrary() {
        guard !state.isBusy else { return }
        libraryService.revealLibrary()
    }

    func applyLibraryImage(_ imageID: UUID) {
        guard let selectedRegionID,
              let index = regions.firstIndex(where: { $0.id == selectedRegionID }),
              let image = watermarkLibrary.images.first(where: { $0.id == imageID }),
              let assetURL = libraryService.imageURL(for: image),
              FileManager.default.fileExists(atPath: assetURL.path),
              !state.isBusy else { return }
        let oldRect = regions[index].imageReplacement?.rectNormalized
        let replacement = WatermarkImageReplacement(
            assetURL: assetURL,
            aspectRatio: CGFloat(image.aspectRatio),
            rectNormalized: oldRect ?? defaultImageRect(
                for: regions[index].rectNormalized,
                imageAspectRatio: CGFloat(image.aspectRatio)
            )
        )
        regions[index].imageReplacement = replacement
        regions[index].imageLibraryID = image.id
        clearFramePreview()
        statusMessage = L10n.tr("subdub.watermark.library.image_applied")
    }

    func removeLibraryImageFromSelectedRegion() {
        guard let selectedRegionID,
              let index = regions.firstIndex(where: { $0.id == selectedRegionID }),
              !state.isBusy else { return }
        regions[index].imageReplacement = nil
        regions[index].imageLibraryID = nil
        clearFramePreview()
    }

    func deleteLibraryImage(_ imageID: UUID) {
        guard !state.isBusy,
              let image = watermarkLibrary.images.first(where: { $0.id == imageID }) else { return }
        do {
            var snapshot = watermarkLibrary
            snapshot.images.removeAll { $0.id == imageID }
            try libraryService.save(snapshot)
            try libraryService.deleteImage(image)
            watermarkLibrary = snapshot
            for index in regions.indices where regions[index].imageLibraryID == imageID {
                regions[index].imageLibraryID = nil
                regions[index].imageReplacement = nil
            }
            clearFramePreview()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyTextStyle(_ styleID: UUID) {
        guard let selectedRegionID,
              let index = regions.firstIndex(where: { $0.id == selectedRegionID }),
              let style = watermarkLibrary.textStyles.first(where: { $0.id == styleID }),
              style.isEnabled,
              !state.isBusy else { return }
        let rect = regions[index].textReplacement?.rectNormalized
            ?? defaultTextRect(for: regions[index].rectNormalized)
        regions[index].textReplacement = WatermarkTextReplacement(
            text: style.text,
            rectNormalized: rect,
            font: style.font,
            color: style.color,
            outlineEnabled: style.outlineEnabled,
            outlineScale: style.outlineScale,
            shadowEnabled: style.shadowEnabled,
            shadowOffsetScale: style.shadowOffsetScale
        )
        regions[index].textStyleID = style.id
        clearFramePreview()
        statusMessage = L10n.tr("subdub.watermark.library.text_applied")
    }

    func removeTextStyleFromSelectedRegion() {
        guard let selectedRegionID,
              let index = regions.firstIndex(where: { $0.id == selectedRegionID }),
              !state.isBusy else { return }
        regions[index].textReplacement = nil
        regions[index].textStyleID = nil
        clearFramePreview()
    }

    func saveTextStyle(_ style: WatermarkLibraryTextStyle, replacingID: UUID? = nil) {
        guard !state.isBusy else { return }
        let normalizedText = style.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !normalizedText.isEmpty else {
            statusMessage = L10n.tr("subdub.watermark.library.invalid_text_style")
            return
        }
        var next = style
        next.text = normalizedText
        var snapshot = watermarkLibrary
        // If no explicit replacingID is provided (e.g. "save new text"), reuse
        // the existing entry that already has the same text so we never end up
        // with duplicate text content in the library.
        let targetID: UUID? = replacingID
            ?? snapshot.textStyles.first(where: { $0.text == normalizedText })?.id
        if let targetID,
           let index = snapshot.textStyles.firstIndex(where: { $0.id == targetID }) {
            snapshot.textStyles[index] = WatermarkLibraryTextStyle(
                id: targetID,
                name: next.name,
                text: next.text,
                font: next.font,
                color: next.color,
                outlineEnabled: next.outlineEnabled,
                outlineScale: next.outlineScale,
                shadowEnabled: next.shadowEnabled,
                shadowOffsetScale: next.shadowOffsetScale
            )
        } else {
            snapshot.textStyles.insert(next, at: 0)
        }
        do {
            try libraryService.save(snapshot)
            watermarkLibrary = snapshot
            refreshRegionReplacementsFromLibrary()
            statusMessage = L10n.tr("subdub.watermark.library.text_saved")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteTextStyle(_ styleID: UUID) {
        guard !state.isBusy else { return }
        var snapshot = watermarkLibrary
        snapshot.textStyles.removeAll { $0.id == styleID }
        do {
            try libraryService.save(snapshot)
            watermarkLibrary = snapshot
            for index in regions.indices where regions[index].textStyleID == styleID {
                regions[index].textStyleID = nil
                regions[index].textReplacement = nil
            }
            clearFramePreview()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func updateReplacementLayer(
        regionID: UUID,
        layer: WatermarkReplacementLayer,
        startingRect: CGRect,
        handle: VideoCropHandle,
        translation: CGSize,
        displaySize: CGSize
    ) {
        guard let index = regions.firstIndex(where: { $0.id == regionID }), !state.isBusy else { return }
        let minSize = VideoCropGeometry.normalizeMinSize(
            minPoints: CGSize(width: 20, height: 20),
            videoDisplaySize: displaySize
        )
        switch layer {
        case .image:
            guard var replacement = regions[index].imageReplacement else { return }
            let aspect = normalizedImageAspectRatio(replacement.aspectRatio)
            let rect = VideoCropGeometry.applyDrag(
                startRect: startingRect,
                translation: translation,
                handle: handle,
                displaySize: displaySize,
                lockedNormalizedAspectRatio: aspect,
                minSize: minSize
            )
            replacement.rectNormalized = VideoCropRect(rect)
            regions[index].imageReplacement = replacement
        case .text:
            guard var replacement = regions[index].textReplacement else { return }
            let initial = VideoCropGeometry.clampNormalizedRect(startingRect)
            let aspect = initial.width / max(initial.height, 0.0001)
            let rect = VideoCropGeometry.applyDrag(
                startRect: startingRect,
                translation: translation,
                handle: handle,
                displaySize: displaySize,
                lockedNormalizedAspectRatio: aspect,
                minSize: minSize
            )
            replacement.rectNormalized = VideoCropRect(rect)
            regions[index].textReplacement = replacement
        }
        selectedRegionID = regionID
        clearFramePreview()
    }

    func togglePlayback() {
        guard isPlayerReady, !state.isBusy else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPreviewPlaying = false
        } else {
            if playbackPosition >= max(sourceDuration - 0.05, 0) {
                player.seek(to: .zero)
                playbackPosition = 0
            }
            player.play()
            isPreviewPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard isPlayerReady, sourceDuration > 0 else { return }
        let target = min(max(seconds, 0), sourceDuration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        playbackPosition = target
        clearFramePreview()
    }

    func previewCurrentFrame() {
        guard let sourceURL, canPreviewFrame else {
            statusMessage = L10n.tr("subdub.watermark.status.region_required")
            return
        }
        player.pause()
        isPreviewPlaying = false
        refreshRegionReplacementsFromLibrary()
        let timestamp = playbackPosition
        let sourceSize = sourceVideoSize
        let repairPreset = selectedRepairPreset
        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("SubDubWatermarkPreview-\(UUID().uuidString).png")
        state = .previewing
        statusMessage = L10n.tr("subdub.watermark.status.previewing")
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await service.previewFrame(
                    sourceURL: sourceURL,
                    timestamp: timestamp,
                    regions: regions,
                    videoSize: sourceSize,
                    repairPreset: repairPreset,
                    outputURL: previewURL
                )
                guard !Task.isCancelled, self.sourceURL == sourceURL else { return }
                previewImage = image
                state = .ready
                statusMessage = L10n.tr("subdub.watermark.status.preview_ready")
            } catch is CancellationError {
                state = hasSource ? .ready : .idle
                statusMessage = L10n.tr("subdub.watermark.status.cancelled")
            } catch {
                if Task.isCancelled {
                    state = hasSource ? .ready : .idle
                    statusMessage = L10n.tr("subdub.watermark.status.cancelled")
                } else {
                    state = .failed
                    statusMessage = errorMessage(for: error)
                }
            }
        }
    }

    func clearFramePreview() {
        previewImage = nil
    }

    func startRemoval() {
        guard requireSubscriptionAccess() else { return }
        guard let sourceURL, canProcess else {
            statusMessage = L10n.tr("subdub.watermark.status.region_required")
            return
        }
        guard let accessToken = DemoFlowOutputDirectoryPolicy.makeVideoCutsAccessToken() else {
            statusMessage = L10n.tr("subdub.video_conversion.status.workspace_missing")
            return
        }
        do {
            refreshRegionReplacementsFromLibrary()
            let outputDirectory = try DemoFlowOutputDirectoryPolicy.prepareVideoCutsDirectory()
            let finalURL = DemoFlowExportFileNamer.availableOutputURL(
                in: outputDirectory,
                prefix: "w",
                fileExtension: "mp4"
            )
            let fileStem = finalURL.deletingPathExtension().lastPathComponent
            let temporaryURL = outputDirectory.appendingPathComponent(
                ".\(fileStem).partial-\(UUID().uuidString).mp4"
            )
            player.pause()
            isPreviewPlaying = false
            clearFramePreview()
            temporaryOutputURL = temporaryURL
            outputURL = nil
            canExportCurrentVideo = false
            progress = 0
            state = .processing
            statusMessage = L10n.tr("subdub.watermark.status.processing")
            let sourceSize = sourceVideoSize
            let processRegions = regions
            let quality = selectedQuality
            let repairPreset = selectedRepairPreset
            let duration = sourceDuration
#if DEBUG
            let onLog: (String) -> Void = { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.statusMessage = line
                }
            }
#else
            let onLog: (String) -> Void = { _ in }
#endif
            activeTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    accessToken.stop()
                    temporaryOutputURL = nil
                }
                do {
                    try await service.removeWatermarks(
                        sourceURL: sourceURL,
                        outputURL: temporaryURL,
                        regions: processRegions,
                        videoSize: sourceSize,
                        repairPreset: repairPreset,
                        quality: quality,
                        duration: duration,
                        onProgress: { [weak self] value in
                            Task { @MainActor [weak self] in self?.progress = value }
                        },
                        onLog: onLog
                    )
                    guard !Task.isCancelled else { throw WatermarkRemovalError.cancelled }
                    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                    outputURL = finalURL
                    progress = 1
                    state = .succeeded
                    statusMessage = L10n.f("subdub.watermark.status.succeeded", finalURL.lastPathComponent)
                    workspace.reveal(finalURL)
                    temporaryOutputURL = nil
                    activeTask = nil
                    onProcessedVideoReady?(finalURL)
                } catch WatermarkRemovalError.cancelled {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    state = hasSource ? .ready : .idle
                    statusMessage = L10n.tr("subdub.watermark.status.cancelled")
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    if Task.isCancelled {
                        state = hasSource ? .ready : .idle
                        statusMessage = L10n.tr("subdub.watermark.status.cancelled")
                    } else {
                        state = .failed
                        statusMessage = errorMessage(for: error)
                    }
                }
            }
        } catch {
            accessToken.stop()
            state = .failed
            statusMessage = errorMessage(for: error)
        }
    }

    func cancelCurrentTask() {
        guard state.isBusy || temporaryOutputURL != nil else { return }
        activeTask?.cancel()
        activeTask = nil
        if let temporaryOutputURL { try? FileManager.default.removeItem(at: temporaryOutputURL) }
        temporaryOutputURL = nil
        state = hasSource ? .ready : .idle
        statusMessage = L10n.tr("subdub.watermark.status.cancelled")
    }

    func resetForNewSharedVideo() {
        if state.isBusy { cancelCurrentTask() }
        activeTask = nil
        clearFramePreview()
        clearReplacementAssets()
        regions = []
        selectedRegionID = nil
        outputURL = nil
        canExportCurrentVideo = false
        exportTask?.cancel()
        exportTask = nil
        isExportingCurrentVideo = false
        preserveExportAvailabilityOnNextSourceChange = false
        progress = 0
    }

    func prepareForProcessedVideoReload() {
        preserveExportAvailabilityOnNextSourceChange = true
    }

    func markCurrentVideoAsProcessed() {
        guard hasSource else { return }
        canExportCurrentVideo = true
    }

    func exportCurrentVideo() {
        guard canExportCurrentVideo,
              !isExportingCurrentVideo,
              !state.isBusy,
              let sourceURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        guard let destinationURL = workspace.pickVideoOutputURL(
            suggestedName: DemoFlowExportFileNamer.fileName(prefix: "w", fileExtension: "mp4")
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }

        let sourcePath = sourceURL.path
        let destinationPath = destinationURL.path
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.deletingPathExtension().lastPathComponent)-partial-\(UUID().uuidString).mp4"
            )
        let temporaryPath = temporaryURL.path
        isExportingCurrentVideo = true
        statusMessage = L10n.tr("subdub.watermark.status.exporting_current")
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .utility) {
                    let fileManager = FileManager.default
                    guard fileManager.fileExists(atPath: sourcePath) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try fileManager.createDirectory(
                        at: URL(fileURLWithPath: destinationPath).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? fileManager.removeItem(atPath: temporaryPath)
                    try fileManager.copyItem(atPath: sourcePath, toPath: temporaryPath)
                    if fileManager.fileExists(atPath: destinationPath) {
                        try fileManager.removeItem(atPath: destinationPath)
                    }
                    try fileManager.moveItem(atPath: temporaryPath, toPath: destinationPath)
                }.value
                guard !Task.isCancelled else { return }
                self.isExportingCurrentVideo = false
                self.exportTask = nil
                self.statusMessage = L10n.f(
                    "subdub.watermark.status.exported_current",
                    destinationURL.lastPathComponent
                )
                self.workspace.reveal(destinationURL)
            } catch is CancellationError {
                self.isExportingCurrentVideo = false
                self.exportTask = nil
            } catch {
                try? FileManager.default.removeItem(atPath: temporaryPath)
                self.isExportingCurrentVideo = false
                self.exportTask = nil
                self.statusMessage = L10n.f(
                    "subdub.status.export_failed",
                    error.localizedDescription
                )
            }
        }
    }

    func revealOutput() {
        guard let outputURL else { return }
        workspace.reveal(outputURL)
    }

    func markReloadFailed() {
        statusMessage = L10n.tr("subdub.watermark.status.reload_failed")
        canExportCurrentVideo = false
        preserveExportAvailabilityOnNextSourceChange = false
    }

    private func syncFromSession() {
        let nextURL = timelineSession.videoURL
        let didChange = sourceURL != nextURL
        let preserveExportAvailability = didChange && preserveExportAvailabilityOnNextSourceChange
        if didChange {
            preserveExportAvailabilityOnNextSourceChange = false
        }
        sourceURL = nextURL
        sourceDuration = timelineSession.sourceDuration
        sourceWaveformSamples = timelineSession.sourceWaveformSamples
        hasAudioTrack = timelineSession.hasSourceAudioTrack
        audioTrackMessage = hasAudioTrack
            ? L10n.tr("subdub.video_conversion.audio_track.available")
            : L10n.tr("subdub.video_conversion.audio_track.loading")
        guard didChange else { return }
        activeTask?.cancel()
        activeTask = nil
        player.pause()
        isPreviewPlaying = false
        playbackPosition = 0
        isPlayerReady = false
        clearFramePreview()
        clearReplacementAssets()
        regions = []
        selectedRegionID = nil
        outputURL = nil
        canExportCurrentVideo = preserveExportAvailability
        exportTask?.cancel()
        exportTask = nil
        isExportingCurrentVideo = false
        progress = 0
        sourceVideoSize = .zero
        sourceWaveformSamples = []
        hasAudioTrack = false
        audioTrackMessage = L10n.tr("subdub.video_conversion.audio_track.loading")
        guard let nextURL else {
            player.replaceCurrentItem(with: nil)
            state = .idle
            statusMessage = L10n.tr("subdub.watermark.status.idle")
            return
        }
        sourceSessionDirectory = timelineSession.sessionDirectory
        let asset = AVURLAsset(url: nextURL)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let track = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video)
                guard let track else { throw WatermarkRemovalError.inputUnavailable }
                let size = try await AVAssetAsyncLoaders.orientedSize(of: track)
                guard sourceURL == nextURL, size.width > 0, size.height > 0 else { return }
                sourceVideoSize = size
                await player.seek(to: .zero)
                isPlayerReady = true
                state = .ready
                statusMessage = L10n.f("subdub.status.imported", nextURL.lastPathComponent)
            } catch {
                guard sourceURL == nextURL else { return }
                state = .failed
                statusMessage = errorMessage(for: error)
            }
        }
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_watermark_removal")
            onRequireSubscription?()
            return false
        }
        return true
    }

    private func errorMessage(for error: Error) -> String {
        switch error {
        case WatermarkRemovalError.dependenciesUnavailable:
            return L10n.tr("subdub.watermark.error.dependencies")
        case WatermarkRemovalError.invalidRegion:
            return L10n.tr("subdub.watermark.error.invalid_region")
        case WatermarkRemovalError.invalidPNG, WatermarkAssetError.invalidPNG:
            return L10n.tr("subdub.watermark.error.invalid_png")
        case WatermarkAssetError.copyFailed:
            return L10n.tr("subdub.watermark.error.png_copy")
        case WatermarkRemovalError.fontUnavailable:
            return L10n.tr("subdub.watermark.error.font")
        case WatermarkRemovalError.invalidTextLayer:
            return L10n.tr("subdub.watermark.error.invalid_text")
        case WatermarkRemovalError.textFileFailed:
            return L10n.tr("subdub.watermark.error.text_file")
        case WatermarkRemovalError.previewFailed:
            return L10n.tr("subdub.watermark.error.preview")
        case WatermarkRemovalError.outputValidationFailed:
            return L10n.tr("subdub.watermark.error.output_validation")
        case let WatermarkRemovalError.probeFailed(reason):
            return L10n.f("subdub.watermark.error.command", "ffprobe: \(reason)")
        case let WatermarkRemovalError.commandFailed(reason):
            return L10n.f("subdub.watermark.error.command", reason)
        default:
            return L10n.f("subdub.watermark.status.failed", error.localizedDescription)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func defaultImageRect(
        for region: VideoCropRect,
        imageAspectRatio: CGFloat
    ) -> VideoCropRect {
        let container = VideoCropGeometry.clampNormalizedRect(region.cgRect)
        let aspect = normalizedImageAspectRatio(imageAspectRatio)
        let containerAspect = container.width / max(container.height, 0.0001)
        let size: CGSize
        if containerAspect > aspect {
            size = CGSize(width: container.height * aspect, height: container.height)
        } else {
            size = CGSize(width: container.width, height: container.width / aspect)
        }
        return VideoCropRect(CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    private func defaultTextRect(for region: VideoCropRect) -> VideoCropRect {
        let container = VideoCropGeometry.clampNormalizedRect(region.cgRect)
        let height = min(0.05, container.height)
        return VideoCropRect(CGRect(
            x: container.minX,
            y: container.minY,
            width: min(max(container.width, 0.2), 0.7),
            height: height
        ))
    }

    private func normalizedImageAspectRatio(_ imageAspectRatio: CGFloat) -> CGFloat {
        guard sourceVideoSize.width > 0, sourceVideoSize.height > 0 else {
            return max(imageAspectRatio, 0.0001)
        }
        return max(imageAspectRatio * sourceVideoSize.height / sourceVideoSize.width, 0.0001)
    }

    private func clearReplacementAssets() {
        workspace.clearWatermarkAssets(in: sourceSessionDirectory)
        sourceSessionDirectory = nil
    }

    private func refreshRegionReplacementsFromLibrary() {
        let imageLookup = Dictionary(uniqueKeysWithValues: watermarkLibrary.images.map { ($0.id, $0) })
        let textLookup = Dictionary(uniqueKeysWithValues: watermarkLibrary.textStyles.map { ($0.id, $0) })
        for index in regions.indices {
            if let imageID = regions[index].imageLibraryID {
                guard let image = imageLookup[imageID],
                      let assetURL = libraryService.imageURL(for: image),
                      FileManager.default.fileExists(atPath: assetURL.path) else {
                    regions[index].imageLibraryID = nil
                    regions[index].imageReplacement = nil
                    continue
                }
                let rect = regions[index].imageReplacement?.rectNormalized
                    ?? defaultImageRect(for: regions[index].rectNormalized, imageAspectRatio: CGFloat(image.aspectRatio))
                regions[index].imageReplacement = WatermarkImageReplacement(
                    assetURL: assetURL,
                    aspectRatio: CGFloat(image.aspectRatio),
                    rectNormalized: rect
                )
            }
            if let styleID = regions[index].textStyleID {
                guard let style = textLookup[styleID], style.isEnabled else {
                    regions[index].textStyleID = nil
                    regions[index].textReplacement = nil
                    continue
                }
                let rect = regions[index].textReplacement?.rectNormalized
                    ?? defaultTextRect(for: regions[index].rectNormalized)
                regions[index].textReplacement = WatermarkTextReplacement(
                    text: style.text,
                    rectNormalized: rect,
                    font: style.font,
                    color: style.color,
                    outlineEnabled: style.outlineEnabled,
                    outlineScale: style.outlineScale,
                    shadowEnabled: style.shadowEnabled,
                    shadowOffsetScale: style.shadowOffsetScale
                )
            }
        }
    }

}
