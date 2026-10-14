import AVFoundation
import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class VideoCompositionViewModel: ObservableObject {
    @Published private(set) var timelineClips: [VideoTimelineClip] = []
    @Published private(set) var timelineClipStartSeconds: [UUID: Double] = [:]
    @Published private(set) var timelineClipThumbnails: [UUID: [VideoTimelineThumbnail]] = [:]
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPlayerReady = false
    @Published private(set) var sourceVideoSize: CGSize = .zero
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var selectedTimelineClipID: UUID?
    @Published private(set) var selectedRange: ClosedRange<Double>?
    @Published private(set) var isExporting = false
    @Published private(set) var isGeneratingCover = false
    @Published private(set) var exportProgress = 0.0
    @Published private(set) var outputURL: URL?
    @Published private(set) var isPreviewMuted = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var deleteStartText = ""
    @Published var deleteEndText = ""
    @Published var coverDurationText = "3"
    @Published private(set) var statusMessage = L10n.tr("subdub.video_composition.status.idle")

    let player = AVPlayer()
    var onCompositionCompleted: ((URL) -> Void)?

    private struct Snapshot {
        let clips: [VideoTimelineClip]
        let clipStarts: [UUID: Double]
        let timelineDurationOverride: Double?
        let position: Double
        let selectedID: UUID?
    }

    private let workspace = SubDubWorkspaceService()
    private let compositionService = VideoTimelineCompositionService()
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?
    private var sessionDirectory: URL?
    private var timeObserver: Any?
    private var previewGeneration = UUID()
    /// Invalidates thumbnail jobs whenever the timeline is structurally
    /// changed by an insertion. Older image-generation tasks may finish out
    /// of order, so they must never write into a newer timeline layout.
    private var thumbnailGeneration = UUID()
    private var pendingInsertionPosition: Double?
    private var coverTask: Task<Void, Never>?
    private var timelineDurationOverride: Double?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var thumbnailCacheBySource: [URL: [VideoTimelineThumbnail]] = [:]
    /// The source currently owned by the shared SubDub timeline.  The first
    /// clip may follow this source when another tab changes the shared video,
    /// while independently-added clips remain untouched.
    private var sharedSourceURL: URL?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackPosition = max(0, min(time.seconds, self.sourceDuration))
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as AnyObject? === self.player.currentItem else { return }
            self.player.pause()
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        self.subscriptionViewModel = subscriptionViewModel
        self.onRequireSubscription = onRequireSubscription
    }

    var hasSource: Bool { !timelineClips.isEmpty }
    var coverClip: VideoTimelineClip? { timelineClips.first(where: \.isCover) }
    var hasCover: Bool { coverClip != nil }
    var coverDuration: Double { coverClip?.durationSeconds ?? 0 }
    var canCompose: Bool { timelineClips.count >= 1 && !isExporting && !isGeneratingCover }
    var canDeleteSelection: Bool {
        guard !isExporting,
              sourceDuration > 0,
              let range = selectedRange,
              range.upperBound - range.lowerBound > 0.001,
              range.lowerBound >= -0.001,
              range.upperBound <= sourceDuration + 0.001 else { return false }
        if let coverClip {
            let coverEnd = coverClip.durationSeconds
            let intersectsCover = range.lowerBound < coverEnd - 0.001 && range.upperBound > 0.001
            if intersectsCover {
                return abs(range.lowerBound) < 0.01 && abs(range.upperBound - coverEnd) < 0.01
            }
        }
        if isSelectionWholeClip(range) {
            return timelineClips.count > 1
        }
        return true
    }
    var totalDurationText: String { formatTime(sourceDuration) }
    var currentTimeText: String { formatTime(playbackPosition) }
    var outputSizeText: String {
        guard sourceVideoSize.width > 0, sourceVideoSize.height > 0 else { return "--" }
        return "\(Int(sourceVideoSize.width.rounded())) × \(Int(sourceVideoSize.height.rounded()))"
    }

    /// Adopt the shared video used by the other SubDub tabs as the first
    /// composition clip.  This intentionally does not copy the file into the
    /// composition draft directory: the shared session owns that copy.
    func adoptSharedVideo(
        url: URL,
        duration: Double,
        sessionDirectory: URL,
        hasAudioTrack: Bool = false
    ) {
        let normalized = url.standardizedFileURL
        guard duration > 0 else { return }

        if let currentShared = sharedSourceURL {
            // Session notifications are frequent (subtitle edits, waveform
            // completion, etc.). Do not reset composition edits while the
            // shared source URL is unchanged.
            if currentShared == normalized {
                if let firstIndex = timelineClips.firstIndex(where: { $0.sourceURL == normalized }),
                   timelineClips[firstIndex].hasAudioTrack != hasAudioTrack {
                    let first = timelineClips[firstIndex]
                    timelineClips[firstIndex] = VideoTimelineClip(
                        id: first.id,
                        sourceURL: first.sourceURL,
                        sourceStartSeconds: first.sourceStartSeconds,
                        sourceEndSeconds: first.sourceEndSeconds,
                        hasAudioTrack: hasAudioTrack,
                        isCover: first.isCover
                    )
                    rebuildPreview()
                }
                return
            }
            guard let sharedIndex = timelineClips.firstIndex(where: { $0.sourceURL == currentShared }) else {
                return
            }
            sourceVideoSize = .zero
            frameRate = 30
            let replacement = VideoTimelineClip(
                sourceURL: normalized,
                sourceStartSeconds: 0,
                sourceEndSeconds: duration,
                hasAudioTrack: hasAudioTrack
            )
            let replacementStart = timelineStartSeconds(for: timelineClips[sharedIndex]) ?? 0
            // A split creates several clips pointing at the shared source.
            // When another tab changes the source, remove all of those old
            // fragments and retain independently-added composition clips.
            let removedIDs = Set(timelineClips.filter { $0.sourceURL == currentShared }.map(\.id))
            timelineClips.removeAll { $0.sourceURL == currentShared }
            removedIDs.forEach { timelineClipStartSeconds.removeValue(forKey: $0) }
            timelineClips.insert(replacement, at: min(sharedIndex, timelineClips.count))
            timelineClipStartSeconds[replacement.id] = replacementStart
            selectedTimelineClipID = replacement.id
        } else if let first = timelineClips.first {
            // Adopt a timeline that was created before the shared session was
            // available, but never overwrite an independent composition draft.
            guard first.sourceURL == normalized else { return }
            sharedSourceURL = normalized
        } else {
            sourceVideoSize = .zero
            frameRate = 30
            timelineClips = [VideoTimelineClip(
                sourceURL: normalized,
                sourceStartSeconds: 0,
                sourceEndSeconds: duration,
                hasAudioTrack: hasAudioTrack
            )]
            timelineClipStartSeconds[timelineClips[0].id] = 0
            selectedTimelineClipID = timelineClips.first?.id
            updateSelectionInputs()
        }

        sharedSourceURL = normalized
        recalculateTimeline()
        playbackPosition = min(playbackPosition, sourceDuration)
        updateSelectionInputs()
        if deleteStartText.isEmpty { deleteStartText = "0.000" }
        if deleteEndText.isEmpty || abs((Double(deleteEndText) ?? -1) - sourceDuration) < 0.0005 {
            deleteEndText = String(format: "%.3f", sourceDuration)
        }
        outputURL = nil
        loadThumbnails(for: timelineClips.prefix(1).map { $0 })
        rebuildPreview()

        // Resolve the actual track metadata in the background.  The session
        // directory parameter is retained in the API to make ownership
        // explicit; composition-added clips continue to use their own temp
        // directory and never remove the shared session.
        _ = sessionDirectory
        Task { [weak self] in
            guard let self else { return }
            let asset = AVAssetAsyncLoaders.makeURLAsset(normalized)
            guard let videoTrack = try? await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else { return }
            let size = try? await AVAssetAsyncLoaders.orientedSize(of: videoTrack)
            let nominal = try? await AVAssetAsyncLoaders.nominalFrameRate(of: videoTrack)
            let actualHasAudio = (try? await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio)) != nil
            await MainActor.run {
                guard self.sharedSourceURL == normalized,
                      let sharedIndex = self.timelineClips.firstIndex(where: { $0.sourceURL == normalized }) else { return }
                if let size, size.width > 0, size.height > 0 { self.sourceVideoSize = size }
                if let nominal, nominal.isFinite, nominal > 0 { self.frameRate = Double(nominal) }
                if self.timelineClips[sharedIndex].hasAudioTrack != actualHasAudio {
                    let sharedClip = self.timelineClips[sharedIndex]
                    self.timelineClips[sharedIndex] = VideoTimelineClip(
                        id: sharedClip.id,
                        sourceURL: sharedClip.sourceURL,
                        sourceStartSeconds: sharedClip.sourceStartSeconds,
                        sourceEndSeconds: sharedClip.sourceEndSeconds,
                        hasAudioTrack: actualHasAudio,
                        isCover: sharedClip.isCover
                    )
                    self.rebuildPreview()
                }
            }
        }
    }

    func importByPanel() {
        guard let urls = workspace.pickVideoCompositionURLs(), !urls.isEmpty else {
            statusMessage = L10n.tr("subdub.video_composition.status.import_cancelled")
            return
        }
        importVideos(urls: urls)
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            let identifier = [
                UTType.mpeg4Movie.identifier,
                UTType.quickTimeMovie.identifier,
                UTType.movie.identifier,
                UTType.fileURL.identifier
            ].first(where: { provider.hasItemConformingToTypeIdentifier($0) })
            guard let identifier else { continue }
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor [weak self] in self?.importVideos(urls: [url]) }
            }
        }
    }

    func importVideos(urls: [URL]) {
        let generation = UUID()
        previewGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                if sessionDirectory == nil { sessionDirectory = try workspace.makeSessionDirectory() }
                var accepted: [VideoTimelineClip] = []
                for url in urls {
                    guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
                        throw VideoCompositionError.unsupportedInput
                    }
                    let persisted = try workspace.persistInput(
                        from: url,
                        kind: .video,
                        sessionDirectory: sessionDirectory!
                    )
                    let asset = AVAssetAsyncLoaders.makeURLAsset(persisted)
                    guard let videoTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else {
                        throw VideoCompositionError.invalidVideo
                    }
                    let duration = try await AVAssetAsyncLoaders.duration(of: asset).seconds
                    guard duration > 0 else { throw VideoCompositionError.invalidVideo }
                    let hasAudio = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .audio) != nil
                    accepted.append(VideoTimelineClip(
                        sourceURL: persisted,
                        sourceStartSeconds: 0,
                        sourceEndSeconds: duration,
                        hasAudioTrack: hasAudio
                    ))
                    if timelineClips.isEmpty && accepted.count == 1 {
                        let size = try await AVAssetAsyncLoaders.orientedSize(of: videoTrack)
                        let nominal = Double(try await AVAssetAsyncLoaders.nominalFrameRate(of: videoTrack))
                        await MainActor.run {
                            self.sourceVideoSize = size
                            if nominal.isFinite, nominal > 0 { self.frameRate = nominal }
                        }
                    }
                }
                guard !accepted.isEmpty else { throw VideoCompositionError.invalidVideo }
                await MainActor.run {
                    guard self.previewGeneration == generation else { return }
                    self.pushUndoSnapshot()
                    let insertionPosition = self.pendingInsertionPosition
                    let isInsertion = insertionPosition != nil && !self.timelineClips.isEmpty
                    if let insertion = insertionPosition, !self.timelineClips.isEmpty {
                        self.insertLoadedClips(accepted, at: insertion)
                    } else {
                        self.appendLoadedClips(accepted)
                    }
                    self.pendingInsertionPosition = nil
                    self.recalculateTimeline()
                    self.selectedTimelineClipID = accepted.first?.id
                    self.updateSelectionInputs()
                    self.statusMessage = isInsertion
                        ? L10n.f("subdub.video_composition.status.inserted", accepted.count)
                        : L10n.f("subdub.video_composition.status.imported", accepted.count)
                    if isInsertion {
                        // Rebuild the visual track immediately with the new
                        // compact duration map. Existing source thumbnails
                        // are remapped synchronously; only uncached inserted
                        // sources require image generation.
                        self.refreshThumbnailsAfterInsertion()
                    } else {
                        self.loadThumbnails(for: accepted)
                    }
                    self.rebuildPreview()
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = self.readableError(error)
                }
            }
        }
    }

    func insertImageCoverByPanel() {
        guard let duration = validatedCoverDuration() else { return }
        guard let url = workspace.pickVideoCompositionImageURL() else {
            statusMessage = L10n.tr("subdub.video_composition.status.cover_import_cancelled")
            return
        }
        startCoverTask(duration: duration, status: "image") { 
            let resolved = url.standardizedFileURL
            let scoped = resolved.startAccessingSecurityScopedResource()
            defer {
                if scoped { resolved.stopAccessingSecurityScopedResource() }
            }
            guard let source = CGImageSourceCreateWithURL(resolved as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw VideoCompositionError.coverFrameUnavailable
            }
            return image
        }
    }

    func insertCurrentFrameCover() {
        guard let duration = validatedCoverDuration() else { return }
        guard let location = location(at: playbackPosition) else {
            statusMessage = L10n.tr("subdub.video_composition.status.cover_frame_unavailable")
            return
        }
        let sourceURL = location.clip.sourceURL
        let sourceTime = location.clip.sourceStartSeconds + location.localSeconds
        startCoverTask(duration: duration, status: "frame") {
            let asset = AVAssetAsyncLoaders.makeURLAsset(sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: sourceTime, preferredTimescale: 600)
            let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? VideoCompositionError.coverFrameUnavailable)
                    }
                }
            }
            return image
        }
    }

    private func validatedCoverDuration() -> Double? {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.video_composition.error.empty")
            return nil
        }
        guard let value = Double(coverDurationText), value.isFinite, value >= 0.5, value <= 30 else {
            statusMessage = readableError(VideoCompositionError.invalidCoverDuration)
            return nil
        }
        guard sourceVideoSize.width > 1, sourceVideoSize.height > 1 else {
            statusMessage = readableError(VideoCompositionError.invalidVideo)
            return nil
        }
        return value
    }

    private func startCoverTask(
        duration: Double,
        status: String,
        imageProvider: @escaping () async throws -> CGImage
    ) {
        coverTask?.cancel()
        isGeneratingCover = true
        statusMessage = status == "image"
            ? L10n.tr("subdub.video_composition.status.cover_preparing_image")
            : L10n.tr("subdub.video_composition.status.cover_preparing_frame")

        coverTask = Task { [weak self] in
            guard let self else { return }
            var generatedURL: URL?
            do {
                let image = try await imageProvider()
                try Task.checkCancellation()
                if self.sessionDirectory == nil {
                    self.sessionDirectory = try self.workspace.makeSessionDirectory()
                }
                guard let sessionDirectory = self.sessionDirectory else {
                    throw VideoCompositionError.outputWorkspaceUnavailable
                }
                let output = sessionDirectory.appendingPathComponent(
                    "Cover-\(UUID().uuidString).mp4"
                )
                generatedURL = output
                let coverURL = try await self.compositionService.makeStillVideo(
                    from: image,
                    renderSize: self.sourceVideoSize,
                    frameRate: self.frameRate,
                    duration: duration,
                    outputURL: output
                )
                let coverClip = VideoTimelineClip(
                    sourceURL: coverURL,
                    sourceStartSeconds: 0,
                    sourceEndSeconds: duration,
                    hasAudioTrack: false,
                    isCover: true
                )
                self.pushUndoSnapshot()
                self.replaceCover(with: coverClip)
                self.recalculateTimeline()
                self.playbackPosition = 0
                self.selectedTimelineClipID = coverClip.id
                self.updateSelectionInputs()
                self.outputURL = nil
                self.refreshThumbnailsAfterInsertion()
                self.rebuildPreview()
                self.statusMessage = status == "image"
                    ? L10n.tr("subdub.video_composition.status.cover_image_set")
                    : L10n.tr("subdub.video_composition.status.cover_frame_set")
                self.isGeneratingCover = false
                self.coverTask = nil
            } catch is CancellationError {
                if let generatedURL { try? FileManager.default.removeItem(at: generatedURL) }
                self.isGeneratingCover = false
                self.coverTask = nil
            } catch {
                if let generatedURL { try? FileManager.default.removeItem(at: generatedURL) }
                self.isGeneratingCover = false
                self.coverTask = nil
                self.statusMessage = self.readableError(error)
            }
        }
    }

    func clearProject() {
        coverTask?.cancel()
        coverTask = nil
        isGeneratingCover = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        thumbnailGeneration = UUID()
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
        timelineClips = []
        timelineClipStartSeconds = [:]
        timelineClipThumbnails = [:]
        thumbnailCacheBySource = [:]
        sourceDuration = 0
        timelineDurationOverride = nil
        playbackPosition = 0
        sourceVideoSize = .zero
        outputURL = nil
        selectedTimelineClipID = nil
        selectedRange = nil
        undoStack = []
        redoStack = []
        sharedSourceURL = nil
        syncHistoryFlags()
        isPlayerReady = false
        statusMessage = L10n.tr("subdub.video_composition.status.cleared")
    }

    func revealOutput() {
        if let outputURL { workspace.reveal(outputURL) }
    }

    func markCompositionCommitted(_ url: URL) {
        outputURL = url
        clearTimelineOnlyKeepingOutput(url)
        statusMessage = L10n.f("subdub.video_composition.status.committed", url.lastPathComponent)
    }

    func reportWorkspaceUnavailable() {
        statusMessage = readableError(VideoCompositionError.outputWorkspaceUnavailable)
    }

    func reportImportCancelled() {
        statusMessage = L10n.tr("subdub.video_composition.status.import_cancelled")
    }

    func reportUnsupportedImport() {
        statusMessage = readableError(VideoCompositionError.unsupportedInput)
    }

    func selectTimelineClip(_ id: UUID) {
        guard timelineClips.contains(where: { $0.id == id }) else { return }
        selectedTimelineClipID = id
        updateSelectionInputs()
    }

    func locateCover() {
        guard let coverClip else { return }
        player.pause()
        isPlaying = false
        selectedTimelineClipID = coverClip.id
        selectedRange = 0...coverClip.durationSeconds
        deleteStartText = "0.000"
        deleteEndText = String(format: "%.3f", coverClip.durationSeconds)
        seek(to: 0)
        statusMessage = L10n.tr("subdub.video_composition.status.cover_located")
    }

    func removeCover() {
        guard let coverClip,
              let coverIndex = timelineClips.firstIndex(where: { $0.id == coverClip.id }) else { return }
        pushUndoSnapshot()
        let removedDuration = coverClip.durationSeconds
        timelineClips.remove(at: coverIndex)
        timelineClipStartSeconds.removeValue(forKey: coverClip.id)
        timelineClipThumbnails.removeValue(forKey: coverClip.id)
        reflowTimelineClipStarts()
        timelineDurationOverride = nil
        playbackPosition = max(0, playbackPosition - removedDuration)
        selectedTimelineClipID = timelineClips.first?.id
        recalculateTimeline()
        updateSelectionInputs()
        outputURL = nil
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.cover_removed")
    }

    /// Select the clip whose visible timeline interval contains `seconds`.
    /// The track uses this rather than per-thumbnail hit testing because the
    /// thumbnail views are positioned with visual offsets and can otherwise
    /// report the wrong clip on macOS.
    func selectTimelineClip(at seconds: Double) {
        guard let location = location(at: seconds) else { return }
        selectTimelineClip(location.clip.id)
    }

    func timelineClipID(at seconds: Double) -> UUID? {
        location(at: seconds)?.clip.id
    }

    func isCoverClip(_ id: UUID) -> Bool {
        timelineClips.first(where: { $0.id == id })?.isCover == true
    }

    /// Confirm the time range without modifying the timeline. Deletion stays
    /// behind the explicit trash action so Return can never remove video.
    func confirmSelectionRangeFromInputs() {
        guard let start = Double(deleteStartText),
              let end = Double(deleteEndText),
              start.isFinite,
              end.isFinite else {
            statusMessage = L10n.tr("subdub.video_composition.status.invalid_range")
            return
        }
        selectRange(start: start, end: end)
    }

    func selectRange(start: Double, end: Double) {
        let lower = max(0, min(start, end))
        let upper = min(sourceDuration, max(start, end))
        guard sourceDuration > 0,
              lower.isFinite,
              upper.isFinite,
              upper - lower > 0.001 else {
            statusMessage = L10n.tr("subdub.video_composition.status.invalid_range")
            return
        }
        selectedRange = lower...upper
        deleteStartText = String(format: "%.3f", lower)
        deleteEndText = String(format: "%.3f", upper)
        if let match = timelineClips.enumerated().first(where: { index, clip in
            let clipStart = timelineStart(of: index)
            return lower < clipStart + clip.durationSeconds && upper > clipStart
        }) {
            selectedTimelineClipID = match.element.id
        }
        statusMessage = L10n.tr("subdub.video_composition.status.selection_confirmed")
    }

    func togglePlayback() {
        guard isPlayerReady else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying = player.timeControlStatus == .playing
    }

    func seek(to seconds: Double) {
        let value = max(0, min(seconds, sourceDuration))
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playbackPosition = value
    }

    func togglePreviewMute() {
        isPreviewMuted.toggle()
        player.isMuted = isPreviewMuted
        statusMessage = L10n.tr(isPreviewMuted
            ? "subdub.video_composition.status.preview_muted"
            : "subdub.video_composition.status.preview_unmuted")
    }

    func splitAtPlayhead() {
        guard let location = location(at: playbackPosition) else {
            statusMessage = L10n.tr("subdub.video_composition.status.split_unavailable")
            return
        }
        guard !location.clip.isCover else {
            statusMessage = L10n.tr("subdub.video_composition.status.split_unavailable")
            return
        }
        let local = location.localSeconds
        guard local > 0.02, local < location.clip.durationSeconds - 0.02,
              let first = location.clip.clipped(to: location.clip.sourceStartSeconds, location.clip.sourceStartSeconds + local),
              let second = location.clip.clipped(to: location.clip.sourceStartSeconds + local, location.clip.sourceEndSeconds) else { return }
        pushUndoSnapshot()
        let sourceThumbnails = timelineClipThumbnails[location.clip.id]
            ?? thumbnailCacheBySource[location.clip.sourceURL]
            ?? []
        let clipStart = location.timelineStart
        timelineClipStartSeconds.removeValue(forKey: location.clip.id)
        timelineClipStartSeconds[first.id] = clipStart
        timelineClipStartSeconds[second.id] = playbackPosition
        timelineClips.replaceSubrange(location.index...location.index, with: [first, second])
        timelineClipThumbnails.removeValue(forKey: location.clip.id)
        timelineClipThumbnails[first.id] = remappedThumbnails(sourceThumbnails, for: first)
        timelineClipThumbnails[second.id] = remappedThumbnails(sourceThumbnails, for: second)
        recalculateTimeline()
        selectedTimelineClipID = second.id
        updateSelectionInputs()
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.split_done")
    }

    func deleteSelectedClip() {
        guard let id = selectedTimelineClipID,
              let index = timelineClips.firstIndex(where: { $0.id == id }) else { return }
        if timelineClips[index].isCover {
            removeCover()
            return
        }
        pushUndoSnapshot()
        timelineDurationOverride = max(sourceDuration, timelineClipEnd(for: timelineClips[index]))
        timelineClipStartSeconds.removeValue(forKey: id)
        timelineClips.remove(at: index)
        selectedTimelineClipID = timelineClips.indices.contains(min(index, timelineClips.count - 1))
            ? timelineClips[min(index, timelineClips.count - 1)].id
            : timelineClips.last?.id
        recalculateTimeline()
        updateSelectionInputs()
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.clip_deleted")
    }

    func deleteSelection() {
        guard let range = selectedRange else {
            deleteSelectedClip()
            return
        }
        if let coverClip, range.lowerBound < coverClip.durationSeconds - 0.001 {
            guard abs(range.lowerBound) < 0.01,
                  abs(range.upperBound - coverClip.durationSeconds) < 0.01 else {
                statusMessage = L10n.tr("subdub.video_composition.status.invalid_range")
                return
            }
        }
        if isSelectionWholeClip(range) {
            deleteSelectedClip()
        } else {
            deleteRange(start: range.lowerBound, end: range.upperBound)
        }
    }

    func deleteRangeFromInputs() {
        guard let start = Double(deleteStartText), let end = Double(deleteEndText) else {
            statusMessage = L10n.tr("subdub.video_composition.status.invalid_range")
            return
        }
        deleteRange(start: start, end: end)
    }

    private func deleteRange(start: Double, end: Double) {
        let lower = max(0, min(start, end))
        let upper = min(sourceDuration, max(start, end))
        guard sourceDuration > 0,
              lower.isFinite,
              upper.isFinite,
              upper - lower > 0.001 else {
            statusMessage = L10n.tr("subdub.video_composition.status.invalid_range")
            return
        }
        if let coverClip, lower < coverClip.durationSeconds - 0.001 {
            guard abs(lower) < 0.01,
                  abs(upper - coverClip.durationSeconds) < 0.01 else {
                statusMessage = L10n.tr("subdub.video_composition.status.invalid_range")
                return
            }
            removeCover()
            return
        }

        var next: [VideoTimelineClip] = []
        var nextStarts: [UUID: Double] = [:]
        var nextThumbnails: [UUID: [VideoTimelineThumbnail]] = [:]
        for clip in timelineClips {
            let clipStart = timelineStartSeconds(for: clip) ?? 0
            let clipEnd = clipStart + clip.durationSeconds
            let overlapStart = max(lower, clipStart)
            let overlapEnd = min(upper, clipEnd)
            let sourceThumbnails = timelineClipThumbnails[clip.id]
                ?? thumbnailCacheBySource[clip.sourceURL]
                ?? []
            if overlapEnd <= overlapStart {
                next.append(clip)
                nextStarts[clip.id] = clipStart
                nextThumbnails[clip.id] = timelineClipThumbnails[clip.id] ?? remappedThumbnails(sourceThumbnails, for: clip)
            } else {
                let localStart = overlapStart - clipStart
                let localEnd = overlapEnd - clipStart
                if localStart > 0.001,
                   let prefix = clip.clipped(to: clip.sourceStartSeconds, clip.sourceStartSeconds + localStart) {
                    next.append(prefix)
                    nextStarts[prefix.id] = clipStart
                    nextThumbnails[prefix.id] = remappedThumbnails(sourceThumbnails, for: prefix)
                }
                if localEnd < clip.durationSeconds - 0.001,
                   let suffix = clip.clipped(to: clip.sourceStartSeconds + localEnd, clip.sourceEndSeconds) {
                    next.append(suffix)
                    nextStarts[suffix.id] = clipStart + localEnd
                    nextThumbnails[suffix.id] = remappedThumbnails(sourceThumbnails, for: suffix)
                }
            }
        }
        guard !next.isEmpty else {
            statusMessage = L10n.tr("subdub.video_composition.status.keep_one_clip")
            return
        }

        pushUndoSnapshot()
        timelineClips = next
        timelineClipStartSeconds = nextStarts
        timelineDurationOverride = max(sourceDuration, upper)
        timelineClipThumbnails = nextThumbnails
        selectedTimelineClipID = next.first?.id
        recalculateTimeline()
        updateSelectionInputs()
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.range_deleted")
    }

    func insertVideoAtPlayheadByPanel() {
        guard let url = workspace.pickVideoCompositionURLs()?.first else {
            reportImportCancelled()
            return
        }
        insertVideos(urls: [url], at: playbackPosition)
    }

    func moveTimelineClip(_ id: UUID, before destinationID: UUID) {
        guard id != destinationID,
              let source = timelineClips.firstIndex(where: { $0.id == id }),
              let destination = timelineClips.firstIndex(where: { $0.id == destinationID }) else { return }
        guard !timelineClips[source].isCover, !timelineClips[destination].isCover else { return }
        pushUndoSnapshot()
        let clip = timelineClips.remove(at: source)
        timelineClips.insert(clip, at: max(0, min(destination - (source < destination ? 1 : 0), timelineClips.count)))
        reflowTimelineClipStarts()
        timelineDurationOverride = nil
        recalculateTimeline()
        updateSelectionInputs()
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.reordered")
    }

    /// Reorder a clip based on the horizontal position where the pointer was
    /// released. This keeps selection and reordering in one timeline gesture,
    /// avoiding SwiftUI's offset hit-testing and native drag/drop conflicts.
    func moveTimelineClip(_ id: UUID, toTimelineSeconds seconds: Double) {
        guard let sourceIndex = timelineClips.firstIndex(where: { $0.id == id }),
              timelineClips.count > 1,
              !timelineClips[sourceIndex].isCover else { return }

        let targetSeconds = max(0, min(seconds, sourceDuration))
        if let location = location(at: targetSeconds), location.clip.id == id {
            return
        }

        let remaining = timelineClips.filter { $0.id != id }
        let firstMovableIndex = remaining.firstIndex(where: { !$0.isCover }) ?? remaining.count
        var insertionIndex = remaining.count
        for (index, clip) in remaining.enumerated() where !clip.isCover {
            let start = timelineStartSeconds(for: clip) ?? 0
            let midpoint = start + clip.durationSeconds / 2
            if targetSeconds < midpoint {
                insertionIndex = index
                break
            }
        }

        var reordered = remaining
        let moving = timelineClips[sourceIndex]
        reordered.insert(moving, at: min(max(insertionIndex, firstMovableIndex), reordered.count))
        guard reordered.map(\.id) != timelineClips.map(\.id) else { return }

        pushUndoSnapshot()
        timelineClips = reordered
        reflowTimelineClipStarts()
        timelineDurationOverride = nil
        recalculateTimeline()
        selectedTimelineClipID = id
        updateSelectionInputs()
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.reordered")
    }

    func moveTimelineClipToEnd(_ id: UUID) {
        guard let index = timelineClips.firstIndex(where: { $0.id == id }),
              !timelineClips[index].isCover,
              index < timelineClips.count - 1 else { return }
        pushUndoSnapshot()
        timelineClips.append(timelineClips.remove(at: index))
        reflowTimelineClipStarts()
        timelineDurationOverride = nil
        recalculateTimeline()
        updateSelectionInputs()
        rebuildPreview()
        statusMessage = L10n.tr("subdub.video_composition.status.reordered")
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeSnapshot())
        restore(snapshot)
        statusMessage = L10n.tr("subdub.video_composition.status.undo")
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        restore(snapshot)
        statusMessage = L10n.tr("subdub.video_composition.status.redo")
    }

    func compose() {
        guard requireSubscriptionAccess(), canCompose else { return }
        guard let outputDirectory = try? DemoFlowOutputDirectoryPolicy.prepareVideoCutsDirectory() else {
            statusMessage = readableError(VideoCompositionError.outputWorkspaceUnavailable)
            return
        }
        guard sourceVideoSize.width > 1, sourceVideoSize.height > 1 else {
            statusMessage = readableError(VideoCompositionError.invalidVideo)
            return
        }
        let output = DemoFlowExportFileNamer.availableOutputURL(
            in: outputDirectory,
            prefix: "j",
            fileExtension: "mp4"
        )
        let project = VideoTimelineCompositionProject(
            clips: timelineClips,
            clipStartSeconds: timelineClips.map { timelineStartSeconds(for: $0) ?? 0 },
            renderSize: sourceVideoSize,
            frameRate: frameRate,
            outputURL: output
        )
        isExporting = true
        exportProgress = 0
        statusMessage = L10n.tr("subdub.video_composition.status.exporting")
        player.pause()
        isPlaying = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await compositionService.export(project: project) { ratio in
                    Task { @MainActor [weak self] in self?.exportProgress = ratio }
                }
                let asset = AVAssetAsyncLoaders.makeURLAsset(result)
                let duration = try await AVAssetAsyncLoaders.duration(of: asset).seconds
                let values = try FileManager.default.attributesOfItem(atPath: result.path)
                guard duration > 0, (values[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                    throw VideoCompositionError.outputEmpty
                }
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgress = 1
                    self.outputURL = result
                    self.statusMessage = L10n.f("subdub.video_composition.status.exported", result.lastPathComponent)
                    self.onCompositionCompleted?(result)
                    self.clearDraftAfterSuccessfulExport()
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    try? FileManager.default.removeItem(at: output)
                    self.statusMessage = self.readableError(error)
                }
            }
        }
    }

    private func insertVideos(urls: [URL], at position: Double) {
        guard !urls.isEmpty else { return }
        // The cover is always the first project item. Inserting while the
        // playhead is inside its short duration means "after cover", never a
        // split that could turn the cover into ordinary clips.
        pendingInsertionPosition = max(coverDuration, max(0, min(position, sourceDuration)))
        importVideos(urls: urls)
        statusMessage = L10n.tr("subdub.video_composition.status.insert_pending")
    }

    private func appendLoadedClips(_ clips: [VideoTimelineClip]) {
        var cursor = max(
            sourceDuration,
            timelineClips.reduce(0) { max($0, timelineClipEnd(for: $1)) }
        )
        for clip in clips {
            timelineClips.append(clip)
            timelineClipStartSeconds[clip.id] = cursor
            cursor += clip.durationSeconds
        }
    }

    /// A composition owns one leading cover. Replacing it preserves the
    /// ordinary clips and their order. Old generated assets stay in the
    /// session directory until the draft is cleared so Undo can restore them.
    private func replaceCover(with cover: VideoTimelineClip) {
        let oldCovers = timelineClips.filter(\.isCover)
        timelineClips.removeAll(where: \.isCover)
        oldCovers.forEach { clip in
            timelineClipStartSeconds.removeValue(forKey: clip.id)
            timelineClipThumbnails.removeValue(forKey: clip.id)
        }
        timelineClips.insert(cover, at: 0)
        reflowTimelineClipStarts()
        timelineDurationOverride = nil
    }

    private func insertLoadedClips(_ clips: [VideoTimelineClip], at position: Double) {
        guard !clips.isEmpty else { return }
        let insertion = max(0, min(position, sourceDuration))
        let insertedDuration = clips.reduce(0) { $0 + $1.durationSeconds }
        guard insertedDuration > 0 else { return }

        var entries: [(clip: VideoTimelineClip, start: Double)] = []
        var inserted = false
        for clip in timelineClips {
            let start = timelineStartSeconds(for: clip) ?? 0
            let end = start + clip.durationSeconds

            if !inserted && insertion > start + 0.001 && insertion < end - 0.001 {
                let local = insertion - start
                if let leading = clip.clipped(
                    to: clip.sourceStartSeconds,
                    clip.sourceStartSeconds + local
                ) {
                    entries.append((leading, start))
                }
                entries.append(contentsOf: clips.enumerated().map { offset, clip in
                    let previous = clips.prefix(offset).reduce(0) { $0 + $1.durationSeconds }
                    return (clip, insertion + previous)
                })
                if let trailing = clip.clipped(
                    to: clip.sourceStartSeconds + local,
                    clip.sourceEndSeconds
                ) {
                    entries.append((trailing, insertion + insertedDuration))
                }
                inserted = true
                continue
            }

            if !inserted && insertion <= start + 0.001 {
                entries.append(contentsOf: clips.enumerated().map { offset, clip in
                    let previous = clips.prefix(offset).reduce(0) { $0 + $1.durationSeconds }
                    return (clip, insertion + previous)
                })
                inserted = true
            }

            entries.append((clip, start >= insertion - 0.001 && inserted ? start + insertedDuration : start))
        }

        if !inserted {
            entries.append(contentsOf: clips.enumerated().map { offset, clip in
                let previous = clips.prefix(offset).reduce(0) { $0 + $1.durationSeconds }
                return (clip, insertion + previous)
            })
        }

        entries.sort { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.001 { return lhs.start < rhs.start }
            return lhs.clip.id.uuidString < rhs.clip.id.uuidString
        }

        // Defensive normalization: insertion must never leave two clips
        // sharing the same visual interval, even when the source timeline
        // already contains gaps or stale starts from an older edit.  Gaps are
        // preserved; only overlapping starts are pushed to the previous end.
        var previousEnd = 0.0
        var normalizedEntries: [(clip: VideoTimelineClip, start: Double)] = []
        normalizedEntries.reserveCapacity(entries.count)
        for entry in entries {
            let start = max(entry.start, previousEnd)
            normalizedEntries.append((entry.clip, start))
            previousEnd = start + entry.clip.durationSeconds
        }
        timelineClips = normalizedEntries.map(\.clip)
        timelineClipStartSeconds = Dictionary(uniqueKeysWithValues: normalizedEntries.map { ($0.clip.id, $0.start) })
    }

    private func refreshThumbnailsAfterInsertion() {
        thumbnailGeneration = UUID()
        let generation = thumbnailGeneration

        // Insertion is the only operation that rebuilds the thumbnail strip.
        // Generate one canonical strip per source, then map that strip back to
        // split clips. Until the async work completes, every clip keeps the
        // same fixed-height placeholder and cannot stretch the layout.
        timelineClipThumbnails = [:]
        thumbnailCacheBySource = [:]
        var representatives: [VideoTimelineClip] = []
        for sourceURL in Set(timelineClips.map(\.sourceURL)) {
            let sourceClips = timelineClips.filter { $0.sourceURL == sourceURL }
            guard let last = sourceClips.max(by: { $0.sourceEndSeconds < $1.sourceEndSeconds }) else { continue }
            representatives.append(
                VideoTimelineClip(
                    sourceURL: sourceURL,
                    sourceStartSeconds: 0,
                    sourceEndSeconds: last.sourceEndSeconds,
                    hasAudioTrack: sourceClips.contains(where: \.hasAudioTrack)
                )
            )
        }
        loadThumbnails(for: representatives, generation: generation)
    }

    private func loadThumbnails(
        for clips: [VideoTimelineClip],
        generation requestedGeneration: UUID? = nil
    ) {
        let generation = requestedGeneration ?? thumbnailGeneration
        for clip in clips {
            if let cached = thumbnailCacheBySource[clip.sourceURL] {
                timelineClipThumbnails[clip.id] = remappedThumbnails(cached, for: clip)
                continue
            }
            if timelineClipThumbnails[clip.id] != nil { continue }
            Task { [weak self] in
                guard let self else { return }
                let asset = AVAssetAsyncLoaders.makeURLAsset(clip.sourceURL)
                guard (try? await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video)) != nil else { return }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let count = max(2, min(8, Int((clip.durationSeconds / 5).rounded()) + 1))
                let times = (0..<count).map { CMTime(seconds: clip.sourceStartSeconds + clip.durationSeconds * Double($0) / Double(max(1, count - 1)), preferredTimescale: 600) }
                var thumbnails: [VideoTimelineThumbnail] = []
                for time in times {
                    if let image = try? await Self.generateCGImage(generator: generator, at: time) {
                        thumbnails.append(VideoTimelineThumbnail(seconds: time.seconds, image: image))
                    }
                }
                await MainActor.run {
                    guard self.thumbnailGeneration == generation,
                          !thumbnails.isEmpty else { return }
                    // Keep the source strip as the canonical cache. Splitting
                    // or trimming only remaps this existing strip; it does
                    // not schedule another thumbnail generation pass.
                    self.thumbnailCacheBySource[clip.sourceURL] = thumbnails
                    for current in self.timelineClips where current.sourceURL == clip.sourceURL {
                        self.timelineClipThumbnails[current.id] = self.remappedThumbnails(thumbnails, for: current)
                    }
                }
            }
        }
    }

    private static func generateCGImage(
        generator: AVAssetImageGenerator,
        at time: CMTime
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? VideoCompositionError.coverFrameUnavailable)
                }
            }
        }
    }

    private func rebuildPreview() {
        let generation = UUID()
        previewGeneration = generation
        let clips = timelineClips
        let starts = clips.map { timelineStartSeconds(for: $0) ?? 0 }
        let restorePosition = max(0, min(playbackPosition, sourceDuration))
        guard !clips.isEmpty else {
            player.pause(); player.replaceCurrentItem(with: nil); isPlayerReady = false; return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await compositionService.makePreviewItem(
                    clips: clips,
                    clipStartSeconds: starts
                )
                await MainActor.run {
                    guard self.previewGeneration == generation else { return }
                    self.player.pause()
                    self.player.replaceCurrentItem(with: item)
                    self.player.isMuted = self.isPreviewMuted
                    self.player.seek(
                        to: CMTime(seconds: restorePosition, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                    self.playbackPosition = restorePosition
                    self.isPlaying = false
                    self.isPlayerReady = true
                }
            } catch {
                await MainActor.run { self.isPlayerReady = false; self.statusMessage = self.readableError(error) }
            }
        }
    }

    private func remappedThumbnails(
        _ thumbnails: [VideoTimelineThumbnail],
        for clip: VideoTimelineClip
    ) -> [VideoTimelineThumbnail] {
        guard !thumbnails.isEmpty else { return [] }
        let matched = thumbnails.filter {
            $0.seconds >= clip.sourceStartSeconds - 0.001 &&
            $0.seconds <= clip.sourceEndSeconds + 0.001
        }
        // A very short split can fall between two canonical sample times.
        // Reuse the nearest existing frame rather than leaving the clip blank;
        // split/delete operations never trigger a new thumbnail generation.
        if !matched.isEmpty { return matched }
        let midpoint = (clip.sourceStartSeconds + clip.sourceEndSeconds) / 2
        guard let nearest = thumbnails.min(by: {
            abs($0.seconds - midpoint) < abs($1.seconds - midpoint)
        }) else { return [] }
        return [nearest]
    }

    private func recalculateTimeline() {
        let contentDuration = timelineClips.reduce(0) { partial, clip in
            max(partial, timelineClipEnd(for: clip))
        }
        sourceDuration = max(timelineDurationOverride ?? 0, contentDuration)
        if playbackPosition > sourceDuration { playbackPosition = sourceDuration }
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func timelineStart(of index: Int) -> Double {
        guard timelineClips.indices.contains(index) else { return 0 }
        return timelineStartSeconds(for: timelineClips[index])
            ?? timelineClips.prefix(index).reduce(0) { $0 + $1.durationSeconds }
    }

    func timelineStartSeconds(for clip: VideoTimelineClip) -> Double? {
        timelineClipStartSeconds[clip.id]
    }

    private func timelineClipEnd(for clip: VideoTimelineClip) -> Double {
        (timelineStartSeconds(for: clip) ?? 0) + clip.durationSeconds
    }

    private func isSelectionWholeClip(_ range: ClosedRange<Double>) -> Bool {
        timelineClips.indices.contains { index in
            let start = timelineStartSeconds(for: timelineClips[index]) ?? timelineStart(of: index)
            let end = start + timelineClips[index].durationSeconds
            return abs(start - range.lowerBound) < 0.01 && abs(end - range.upperBound) < 0.01
        }
    }

    private func location(at seconds: Double) -> (index: Int, clip: VideoTimelineClip, localSeconds: Double, timelineStart: Double)? {
        for (index, clip) in timelineClips.enumerated() {
            let start = timelineStartSeconds(for: clip) ?? timelineStart(of: index)
            let end = start + clip.durationSeconds
            if seconds >= start && (seconds < end || (index == timelineClips.indices.last && seconds <= end)) {
                return (index, clip, max(0, min(seconds - start, clip.durationSeconds)), start)
            }
        }
        return nil
    }

    private func reflowTimelineClipStarts() {
        var cursor = 0.0
        timelineClipStartSeconds = Dictionary(uniqueKeysWithValues: timelineClips.map { clip in
            defer { cursor += clip.durationSeconds }
            return (clip.id, cursor)
        })
    }

    private func pushUndoSnapshot() {
        undoStack.append(makeSnapshot())
        redoStack.removeAll()
        syncHistoryFlags()
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            clips: timelineClips,
            clipStarts: timelineClipStartSeconds,
            timelineDurationOverride: timelineDurationOverride,
            position: playbackPosition,
            selectedID: selectedTimelineClipID
        )
    }
    private func restore(_ snapshot: Snapshot) {
        timelineClips = snapshot.clips
        timelineClipStartSeconds = snapshot.clipStarts
        timelineDurationOverride = snapshot.timelineDurationOverride
        playbackPosition = snapshot.position
        selectedTimelineClipID = snapshot.selectedID
        recalculateTimeline()
        updateSelectionInputs()
        rebuildPreview()
        syncHistoryFlags()
    }
    private func syncHistoryFlags() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    private func updateSelectionInputs() {
        guard let id = selectedTimelineClipID,
              let index = timelineClips.firstIndex(where: { $0.id == id }) else {
            selectedRange = nil
            return
        }
        let start = timelineStartSeconds(for: timelineClips[index]) ?? timelineStart(of: index)
        let end = start + timelineClips[index].durationSeconds
        selectedRange = start...end
        deleteStartText = String(format: "%.3f", start)
        deleteEndText = String(format: "%.3f", end)
    }

    private func clearTimelineOnlyKeepingOutput(_ url: URL) {
        player.pause(); player.replaceCurrentItem(with: nil)
        let duration = sourceDuration
        timelineClips = [VideoTimelineClip(sourceURL: url, sourceStartSeconds: 0, sourceEndSeconds: duration, hasAudioTrack: true)]
        timelineClipStartSeconds = [timelineClips[0].id: 0]
        timelineDurationOverride = nil
        selectedTimelineClipID = timelineClips.first?.id
        updateSelectionInputs()
        undoStack = []; redoStack = []; syncHistoryFlags()
    }

    private func clearDraftAfterSuccessfulExport() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        thumbnailGeneration = UUID()
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
        timelineClips = []
        timelineClipStartSeconds = [:]
        timelineClipThumbnails = [:]
        thumbnailCacheBySource = [:]
        sourceDuration = 0
        timelineDurationOverride = nil
        playbackPosition = 0
        selectedTimelineClipID = nil
        selectedRange = nil
        undoStack = []
        redoStack = []
        sharedSourceURL = nil
        syncHistoryFlags()
        isPlayerReady = false
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_video_export")
            onRequireSubscription?()
            return false
        }
        return true
    }

    private func readableError(_ error: Error) -> String {
        "\(L10n.tr("subdub.error.reason_prefix")) \(error.localizedDescription)\n\(L10n.tr("subdub.error.next_step_prefix")) \(L10n.tr("subdub.video_composition.error.next_step"))"
    }

    private func formatTime(_ value: Double) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
