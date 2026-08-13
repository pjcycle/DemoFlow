import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SubtitleBurnViewModel: NSObject, ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var sourceVideoSize: CGSize = .zero
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var sourceWaveformSamples: [Double] = []
    @Published var cues: [SubtitleTimelineCue] = []
    @Published var subtitleStyle: SubtitleStylePreset = .standard
    @Published var subtitleThemeColor: SubtitleThemeColor = .white
    @Published var previewPosition: SubtitlePreviewPosition = .default
    @Published var selectedCueID: UUID?
    @Published private(set) var state: SubtitleBurnState = .idle
    @Published private(set) var statusMessage: String = L10n.tr("subdub.subtitle_burn.status.idle")
    @Published private(set) var isPlayerReady = false

    let player = AVPlayer()
    var onVideoImportResult: ((URL, Result<Void, Error>) -> Void)?

    private let timelineSession: SubDubTimelineSession
    private let workspace = SubDubWorkspaceService()
    private let parser: SubtitleParser = SRTVTTSubtitleParser()
    private let exportService = SubDubExportService()
    private let waveformService = SubDubWaveformService()
    private let transcriptionService = WhisperTranscriptionService()
    private var sessionDirectory: URL?
    private var timeObserverToken: Any?
    private var timelineCancellable: AnyCancellable?
    private var activeTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var retainedVideoImportAccessToken: OutputLocationAccessToken?
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?

    init(timelineSession: SubDubTimelineSession) {
        self.timelineSession = timelineSession
        super.init()
        timelineCancellable = timelineSession.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncFromTimelineSession()
                }
            }
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackPosition = max(0, time.seconds)
            }
        }
    }

    deinit {
        activeTask?.cancel()
        waveformTask?.cancel()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timelineCancellable?.cancel()
    }

    var hasSource: Bool { sourceURL != nil && sourceDuration > 0 }
    var hasCues: Bool { !cues.isEmpty }
    var canBurn: Bool { hasSource && hasCues && !state.isBusy }
    var selectedCue: SubtitleTimelineCue? {
        cues.first { $0.id == selectedCueID }
    }
    var activeCue: SubtitleTimelineCue? {
        guard hasSource else { return nil }
        return cues.first { cue in
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty &&
                playbackPosition >= cue.startTime &&
                playbackPosition < cue.endTime
        }
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        self.subscriptionViewModel = subscriptionViewModel
        self.onRequireSubscription = onRequireSubscription
    }

    func importVideoByPanel() {
        guard let url = workspace.pickVideoURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importVideo(from: url)
    }

    func reportImportCancelled() {
        statusMessage = L10n.tr("subdub.status.import_cancelled")
    }

    func importSubtitleByPanel() {
        guard let url = workspace.pickSubtitleURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importSubtitle(from: url)
    }

    func importTimelineJSONByPanel() {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard let url = workspace.pickTimelineJSONURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importTimelineJSON(from: url)
    }

    func exportTimelineJSONByPanel() {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        do {
            try validateCues()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard let sourceURL,
              let outputURL = workspace.pickTimelineJSONOutputURL(
                  suggestedName: "\(sourceURL.deletingPathExtension().lastPathComponent)-字幕.json"
              ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }

        do {
            let document = SubtitleTimelineDocument(
                sourceDuration: sourceDuration,
                style: subtitleStyle,
                themeColor: subtitleThemeColor,
                cues: cues
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: outputURL, options: .atomic)
            statusMessage = L10n.f("subdub.status.timeline_exported", outputURL.lastPathComponent)
        } catch {
            statusMessage = L10n.f("subdub.status.timeline_export_failed", error.localizedDescription)
        }
    }

    func importVideo(from url: URL) {
        importVideo(from: url, retainingAccessToken: nil)
    }

    func importVideo(
        from url: URL,
        retainingAccessToken accessToken: OutputLocationAccessToken?
    ) {
        activeTask?.cancel()
        waveformTask?.cancel()
        retainedVideoImportAccessToken?.stop()
        retainedVideoImportAccessToken = accessToken
        activeTask = Task { [weak self] in
            await self?.loadVideo(from: url, retainingAccessToken: accessToken)
        }
    }

    func importSubtitle(from url: URL) {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.loadSubtitle(from: url)
        }
    }

    func importTimelineJSON(from url: URL) {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.loadTimelineJSON(from: url)
        }
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let identifiers = [
            UTType.movie.identifier,
            UTType.plainText.identifier,
            UTType.fileURL.identifier
        ]
        guard let identifier = identifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else { return }
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                if ["srt", "vtt"].contains(url.pathExtension.lowercased()) {
                    self?.importSubtitle(from: url)
                } else {
                    self?.importVideo(from: url)
                }
            }
        }
    }

    func removeVideo() {
        activeTask?.cancel()
        activeTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        retainedVideoImportAccessToken?.stop()
        retainedVideoImportAccessToken = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        timelineSession.clearProject()
        sessionDirectory = nil
        sourceURL = nil
        sourceDuration = 0
        sourceVideoSize = .zero
        playbackPosition = 0
        sourceWaveformSamples = []
        cues = []
        subtitleStyle = .standard
        subtitleThemeColor = .white
        selectedCueID = nil
        isPlayerReady = false
        state = .idle
        statusMessage = L10n.tr("subdub.subtitle_burn.status.video_removed")
    }

    func generateSubtitles() {
        guard hasSource, let sessionDirectory else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard !state.isBusy else { return }
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                state = .extractingAudio
                statusMessage = L10n.tr("subdub.subtitle_burn.status.extracting_audio")
                let audioURL = try await prepareSourceAudio(in: sessionDirectory)
                guard !Task.isCancelled else { throw CancellationError() }
                state = .transcribing
                statusMessage = L10n.tr("subdub.subtitle_burn.status.transcribing")
                let result = try await transcriptionService.transcribe(
                    audioURL: audioURL,
                    sessionDirectory: sessionDirectory
                )
                guard !Task.isCancelled else { throw CancellationError() }
                cues = normalize(result)
                selectedCueID = cues.first?.id
                try persistCues()
                state = .ready
                statusMessage = L10n.f("subdub.subtitle_burn.status.generated", cues.count)
            } catch is CancellationError {
                state = hasSource ? .ready : .idle
                statusMessage = L10n.tr("subdub.subtitle_burn.status.cancelled")
            } catch {
                if Task.isCancelled {
                    state = hasSource ? .ready : .idle
                    statusMessage = L10n.tr("subdub.subtitle_burn.status.cancelled")
                } else {
                    state = .failed
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelCurrentTask() {
        guard state.isBusy else { return }
        activeTask?.cancel()
        activeTask = nil
        state = hasSource ? .ready : .idle
        statusMessage = L10n.tr("subdub.subtitle_burn.status.cancelled")
    }

    func stopPlaybackForSourceReplacement() {
        player.pause()
        playbackPosition = 0
    }

    func importSubtitleAndReplace(from url: URL) {
        importSubtitle(from: url)
    }

    func selectCue(_ id: UUID) {
        selectedCueID = id
        guard let cue = cues.first(where: { $0.id == id }) else { return }
        player.pause()
        player.seek(to: CMTime(seconds: cue.startTime, preferredTimescale: 600))
        playbackPosition = cue.startTime
    }

    func updateCueTime(id: UUID, startText: String, endText: String) {
        guard let start = parseTime(startText), let end = parseTime(endText) else {
            statusMessage = L10n.tr("subdub.subtitle_burn.status.invalid_time")
            return
        }
        guard validateRange(start: start, end: end) else {
            statusMessage = L10n.tr("subdub.subtitle_burn.status.invalid_time")
            return
        }
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index].startTime = start
        cues[index].endTime = end
        selectedCueID = id
        persistCuesIfPossible()
    }

    func updateCueText(id: UUID, text: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index].text = text
        selectedCueID = id
        persistCuesIfPossible()
    }

    func updateSubtitleStyle(_ style: SubtitleStylePreset) {
        subtitleStyle = style
        persistCuesIfPossible()
    }

    func updateSubtitleThemeColor(_ color: SubtitleThemeColor) {
        subtitleThemeColor = color
        persistCuesIfPossible()
    }

    func updatePreviewPosition(_ position: SubtitlePreviewPosition) {
        previewPosition = position
    }

    func addCue() {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        let start = min(max(playbackPosition, 0), max(sourceDuration - 0.2, 0))
        let end = min(start + 2, sourceDuration)
        guard end - start >= 0.1 else { return }
        let cue = SubtitleTimelineCue(
            startTime: start,
            endTime: end,
            text: L10n.tr("subdub.subtitle_burn.default_text")
        )
        cues.append(cue)
        selectedCueID = cue.id
        persistCuesIfPossible()
    }

    func removeCue(_ id: UUID) {
        cues.removeAll { $0.id == id }
        if selectedCueID == id {
            selectedCueID = cues.first?.id
        }
        persistCuesIfPossible()
    }

    func togglePlayback() {
        guard isPlayerReady else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if playbackPosition >= max(sourceDuration - 0.05, 0) {
                player.seek(to: .zero)
                playbackPosition = 0
            }
            player.play()
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
    }

    func burnSubtitles() {
        guard requireSubscriptionAccess() else { return }
        guard canBurn,
              let sourceURL,
              let sessionDirectory,
              sourceVideoSize.width > 0,
              sourceVideoSize.height > 0 else {
            statusMessage = L10n.tr("subdub.subtitle_burn.status.invalid_input")
            return
        }
        do {
            try validateCues()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard let outputURL = workspace.pickVideoOutputURL(
            suggestedName: "\(sourceURL.deletingPathExtension().lastPathComponent)-字幕烧制.mp4"
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }

        let exportCues = cues
        let exportStyle = subtitleStyle
        let exportThemeColor = subtitleThemeColor
        let exportVideoSize = sourceVideoSize
        let exportDuration = sourceDuration
        state = .exporting
        statusMessage = L10n.tr("subdub.subtitle_burn.status.exporting")
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await exportService.burnSubtitles(
                    videoURL: sourceURL,
                    cues: exportCues,
                    outputURL: outputURL,
                    duration: exportDuration,
                    sessionDirectory: sessionDirectory,
                    videoSize: exportVideoSize,
                    style: exportStyle,
                    themeColor: exportThemeColor
                )
                state = .succeeded
                statusMessage = L10n.f("subdub.status.exported", outputURL.lastPathComponent)
                workspace.reveal(outputURL)
            } catch is CancellationError {
                state = .ready
                statusMessage = L10n.tr("subdub.subtitle_burn.status.cancelled")
            } catch {
                if Task.isCancelled {
                    state = .ready
                    statusMessage = L10n.tr("subdub.subtitle_burn.status.cancelled")
                } else {
                    state = .failed
                    statusMessage = L10n.f("subdub.status.export_failed", error.localizedDescription)
                }
            }
        }
    }

    private func loadVideo(
        from url: URL,
        retainingAccessToken accessToken: OutputLocationAccessToken?
    ) async {
        defer {
            if let accessToken {
                accessToken.stop()
                if retainedVideoImportAccessToken === accessToken {
                    retainedVideoImportAccessToken = nil
                }
            }
        }
        state = .preparing
        statusMessage = L10n.tr("subdub.status.importing")
        let previousSession = sessionDirectory
        do {
            let session = try workspace.makeSessionDirectory()
            let persistedURL = try workspace.persistInput(
                from: url,
                kind: .video,
                sessionDirectory: session
            )
            let asset = AVURLAsset(url: persistedURL)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0,
                  let videoTrack = try await AVAssetAsyncLoaders.firstTrack(in: asset, mediaType: .video) else {
                throw SubDubError.videoValidationFailed
            }
            let videoSize = try await AVAssetAsyncLoaders.orientedSize(of: videoTrack)
            guard videoSize.width > 0, videoSize.height > 0 else {
                throw SubDubError.videoValidationFailed
            }

            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            await player.seek(to: .zero)
            try timelineSession.configureProject(
                videoURL: persistedURL,
                duration: duration.seconds,
                sessionDirectory: session
            )
            sessionDirectory = session
            sourceURL = persistedURL
            sourceDuration = duration.seconds
            sourceVideoSize = videoSize
            playbackPosition = 0
            sourceWaveformSamples = []
            cues = []
            subtitleStyle = .standard
            subtitleThemeColor = .white
            selectedCueID = nil
            isPlayerReady = true
            state = .ready
            statusMessage = L10n.f("subdub.status.imported", persistedURL.lastPathComponent)
            onVideoImportResult?(url, .success(()))
            if let previousSession, previousSession != session {
                try? FileManager.default.removeItem(at: previousSession)
            }
            waveformTask?.cancel()
            let waveformURL = session.appendingPathComponent(
                "SourceWaveform-\(UUID().uuidString).pcm"
            )
            waveformTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let samples = try await exportService.extractWaveformSamples(
                        from: persistedURL,
                        outputURL: waveformURL
                    )
                    guard !Task.isCancelled,
                          self.sourceURL == persistedURL,
                          self.sessionDirectory == session else { return }
                    timelineSession.updateSourceWaveform(
                        samples: samples,
                        hasAudioTrack: true
                    )
                    sourceWaveformSamples = samples
                } catch {
                    guard !Task.isCancelled,
                          self.sourceURL == persistedURL,
                          self.sessionDirectory == session else { return }
                    timelineSession.updateSourceWaveform(
                        samples: [],
                        hasAudioTrack: false
                    )
                    sourceWaveformSamples = []
                }
            }
        } catch is CancellationError {
            state = hasSource ? .ready : .idle
            statusMessage = L10n.tr("subdub.subtitle_burn.status.cancelled")
            onVideoImportResult?(url, .failure(CancellationError()))
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
            onVideoImportResult?(url, .failure(error))
        }
    }

    private func loadSubtitle(from url: URL) async {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        do {
            let session = sessionDirectory ?? timelineSession.sessionDirectory
            guard let session else { throw SubDubError.outputUnavailable }
            let persistedURL = try workspace.persistInput(
                from: url,
                kind: .subtitle,
                sessionDirectory: session
            )
            let parsed = try parser.parse(url: persistedURL)
            cues = normalize(parsed.map(SubtitleTimelineCue.init(cue:)))
            selectedCueID = cues.first?.id
            try persistCues()
            state = .ready
            statusMessage = L10n.f("subdub.status.subtitle_imported", persistedURL.lastPathComponent)
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func loadTimelineJSON(from url: URL) async {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }

        do {
            let resolvedURL = url.standardizedFileURL
            guard resolvedURL.isFileURL,
                  FileManager.default.fileExists(atPath: resolvedURL.path) else {
                throw SubDubError.inputUnavailable
            }
            let isAccessingSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
            defer {
                if isAccessingSecurityScope {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: resolvedURL)
            let document = try JSONDecoder().decode(SubtitleTimelineDocument.self, from: data)
            guard (1...3).contains(document.schemaVersion) else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.error.timeline_schema")
                )
            }
            guard document.sourceDuration > 0 else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.error.subtitle_out_of_range")
                )
            }
            guard abs(document.sourceDuration - sourceDuration) <= 0.5 else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.error.timeline_source_mismatch")
                )
            }
            guard document.cues.allSatisfy({ cue in
                validateRange(start: cue.startTime, end: cue.endTime)
                    && !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.subtitle_burn.status.invalid_cue")
                )
            }

            let importedCues = normalize(document.cues)
            guard !importedCues.isEmpty else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.error.no_cues")
                )
            }
            guard importedCues.count == document.cues.count else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.subtitle_burn.status.invalid_cue")
                )
            }

            cues = importedCues
            subtitleStyle = document.style
            subtitleThemeColor = document.themeColor
            selectedCueID = cues.first?.id
            try persistCues()
            state = .ready
            statusMessage = L10n.f(
                "subdub.status.timeline_imported",
                resolvedURL.lastPathComponent
            )
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func prepareSourceAudio(in session: URL) async throws -> URL {
        if let existing = timelineSession.sourceAudioURL,
           FileManager.default.fileExists(atPath: existing.path) {
            sourceWaveformSamples = timelineSession.sourceWaveformSamples
            return existing
        }
        let audioURL = session.appendingPathComponent("SourceAudio-16k.wav")
        guard let videoURL = sourceURL ?? timelineSession.videoURL else {
            throw SubDubError.inputMissing
        }
        try await exportService.extractAudioForTranscription(
            from: videoURL,
            outputURL: audioURL
        )
        let samples = (try? await waveformService.samples(from: audioURL)) ?? []
        timelineSession.updateSourceAudio(url: audioURL, waveformSamples: samples)
        sourceWaveformSamples = samples
        return audioURL
    }

    private func normalize(_ values: [SubtitleTimelineCue]) -> [SubtitleTimelineCue] {
        values.compactMap { cue in
            let start = min(max(cue.startTime, 0), max(sourceDuration - 0.1, 0))
            let end = min(max(cue.endTime, start + 0.1), sourceDuration)
            guard end > start, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            var normalized = cue
            normalized.startTime = start
            normalized.endTime = end
            normalized.text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
        .sorted { $0.startTime < $1.startTime }
    }

    private func persistCues() throws {
        let document = SubtitleTimelineDocument(
            sourceDuration: sourceDuration,
            style: subtitleStyle,
            themeColor: subtitleThemeColor,
            cues: cues
        )
        try timelineSession.updateDocument(document)
    }

    private func persistCuesIfPossible() {
        do {
            try persistCues()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func syncFromTimelineSession() {
        guard !state.isBusy else { return }
        sourceURL = timelineSession.videoURL
        sourceDuration = timelineSession.sourceDuration
        sourceWaveformSamples = timelineSession.sourceWaveformSamples
        guard let document = timelineSession.document else {
            if !cues.isEmpty {
                cues = []
                selectedCueID = nil
            }
            return
        }
        if cues != document.cues {
            cues = document.cues
            selectedCueID = selectedCueID.flatMap { id in
                cues.contains(where: { $0.id == id }) ? id : cues.first?.id
            } ?? cues.first?.id
        }
        if subtitleStyle != document.style {
            subtitleStyle = document.style
        }
        if subtitleThemeColor != document.themeColor {
            subtitleThemeColor = document.themeColor
        }
    }

    private func validateCues() throws {
        guard !cues.isEmpty else {
            throw SubDubError.subtitleBurnValidationFailed(
                L10n.tr("subdub.error.no_cues")
            )
        }
        for cue in cues {
            guard validateRange(start: cue.startTime, end: cue.endTime),
                  !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SubDubError.subtitleBurnValidationFailed(
                    L10n.tr("subdub.subtitle_burn.status.invalid_cue")
                )
            }
        }
    }

    private func validateRange(start: Double, end: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end <= sourceDuration && end - start >= 0.1
    }

    private func parseTime(_ value: String) -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        if parts.count >= 2 {
            guard let seconds = Double(parts.last ?? ""),
                  let minutes = Double(parts[parts.count - 2]) else { return nil }
            let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
            return hours * 3600 + minutes * 60 + seconds
        }
        return Double(normalized)
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_subtitle_burn")
            onRequireSubscription?()
            return false
        }
        return true
    }
}
