import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AudioReplacementViewModel: ObservableObject {
    let timelineSession: SubDubTimelineSession
    let player = AVPlayer()

    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var sourceVideoSize: CGSize = .zero
    @Published private(set) var sourceWaveformSamples: [Double] = []
    @Published private(set) var replacementWaveformSamples: [Double] = []
    @Published private(set) var replacementWaveformDuration: Double = 0
    @Published private(set) var importedWaveformSamples: [Double] = []
    @Published private(set) var importedWaveformDuration: Double = 0
    @Published private(set) var cues: [SubtitleTimelineCue] = []
    @Published var selectedCueID: UUID?
    @Published var languageMode: AudioReplacementLanguageMode = .automatic
    @Published var selectedVoiceIdentifier = ""
    @Published var rate: Double = 1.0
    @Published private(set) var state: AudioReplacementState = .idle
    @Published private(set) var statusMessage: String
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var isPlayerReady = false
    @Published private(set) var previewMode: AudioPreviewMode = .original
    @Published private(set) var replacementAudioURL: URL?
    @Published private(set) var importedAudioURL: URL?
    @Published private(set) var cueStatuses: [UUID: AudioReplacementCueStatus] = [:]

    private let workspace = SubDubWorkspaceService()
    private let exportService = SubDubExportService()
    private let speechService = AppleSpeechSynthesisService()
    private let previewService = SubDubPreviewCompositionService()
    private let waveformService = SubDubWaveformService()
    private var draft = AudioReplacementDraft()
    private var sessionCancellable: AnyCancellable?
    private var timeObserverToken: Any?
    private var activeTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?

    init(timelineSession: SubDubTimelineSession) {
        self.timelineSession = timelineSession
        statusMessage = L10n.tr("subdub.audio_replacement.status.idle")

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
                self?.playbackPosition = max(0, time.seconds)
            }
        }
        syncFromSession()
    }

    deinit {
        activeTask?.cancel()
        previewTask?.cancel()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
    }

    var hasSource: Bool { sourceURL != nil && sourceDuration > 0 }
    var hasCues: Bool { !cues.isEmpty }
    var hasReplacementAudio: Bool { replacementAudioURL != nil }
    var hasImportedAudio: Bool { importedAudioURL != nil }
    var overlayWaveformSamples: [Double] {
        guard let mode = overlayWaveformMode else { return [] }
        switch mode {
        case .replacement: return replacementWaveformSamples
        case .imported: return importedWaveformSamples
        case .original: return []
        }
    }
    var overlayWaveformDuration: Double {
        guard let mode = overlayWaveformMode else { return 0 }
        switch mode {
        case .replacement: return replacementWaveformDuration
        case .imported: return importedWaveformDuration
        case .original: return 0
        }
    }
    var overlayWaveformTitle: String? {
        guard let mode = overlayWaveformMode else { return nil }
        switch mode {
        case .replacement: return L10n.tr("subdub.audio_replacement.preview.replacement")
        case .imported: return L10n.tr("subdub.audio_replacement.preview.imported")
        case .original: return nil
        }
    }
    var availablePreviewModes: [AudioPreviewMode] {
        var modes: [AudioPreviewMode] = [.original]
        if hasReplacementAudio { modes.append(.replacement) }
        if hasImportedAudio { modes.append(.imported) }
        return modes
    }
    var sourceName: String {
        sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video")
    }
    var cueCount: Int { cues.count }
    var generatedCueCount: Int {
        cueStatuses.values.filter { $0 == .generated }.count
    }
    var timelineStatus: String {
        cueCount > 0
            ? L10n.f("subdub.audio_replacement.timeline_ready", cueCount)
            : L10n.tr("subdub.audio_replacement.timeline_empty")
    }
    var playbackPositionText: String {
        "\(formatSubtitleTime(playbackPosition)) / \(formatSubtitleTime(sourceDuration))"
    }
    var canExport: Bool {
        guard hasSource, hasCues, !state.isBusy else { return false }
        if previewMode == .imported {
            return importedAudioURL != nil
        }
        return hasReplacementAudio && allCuesGenerated
    }
    var canAudioReplaceExport: Bool {
        hasSource && !state.isBusy && selectedExportAudioURL != nil
    }
    var selectedCue: SubtitleTimelineCue? {
        cues.first { $0.id == selectedCueID }
    }

    var voiceOptions: [AudioReplacementVoiceOption] {
        let automatic = AudioReplacementVoiceOption(
            id: "",
            title: L10n.tr("subdub.audio_replacement.voice.automatic")
        )
        let language = languageMode.localeIdentifier
        let voices = speechService.availableVoices(for: language).map {
            AudioReplacementVoiceOption(
                id: $0.identifier,
                title: "\($0.name) (\($0.language))"
            )
        }
        return [automatic] + voices
    }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        self.subscriptionViewModel = subscriptionViewModel
        self.onRequireSubscription = onRequireSubscription
    }

    func selectCue(_ id: UUID) {
        selectedCueID = id
        guard let cue = cues.first(where: { $0.id == id }) else { return }
        player.pause()
        player.seek(to: CMTime(seconds: cue.startTime, preferredTimescale: 600))
        playbackPosition = cue.startTime
    }

    func updateCueText(id: UUID, text: String) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index].text = text
        selectedCueID = id
        invalidateCue(id)
        persistCues()
    }

    func removeCue(_ id: UUID) {
        guard cues.contains(where: { $0.id == id }) else { return }
        cues.removeAll { $0.id == id }
        draft.cueAudioURLs[id] = nil
        draft.cueSignatures[id] = nil
        draft.cueStatuses[id] = nil
        cueStatuses[id] = nil
        if selectedCueID == id {
            selectedCueID = cues.first?.id
        }
        replacementAudioURL = nil
        draft.replacementAudioURL = nil
        replacementWaveformSamples = []
        replacementWaveformDuration = 0
        if previewMode == .replacement {
            previewMode = .original
            reloadPreview()
        }
        persistCues()
        persistManifest()
    }

    func updateLanguageMode(_ mode: AudioReplacementLanguageMode) {
        guard languageMode != mode else { return }
        languageMode = mode
        selectedVoiceIdentifier = ""
        draft.languageMode = mode
        draft.voiceIdentifier = nil
        invalidateGeneratedAudio()
    }

    func updateVoiceIdentifier(_ identifier: String) {
        guard selectedVoiceIdentifier != identifier else { return }
        selectedVoiceIdentifier = identifier
        draft.voiceIdentifier = identifier.isEmpty ? nil : identifier
        invalidateGeneratedAudio()
    }

    func updateRate(_ value: Double) {
        let nextRate = min(max(value, 0.5), 2.0)
        guard abs(rate - nextRate) > 0.001 else { return }
        rate = nextRate
        draft.rate = rate
        invalidateGeneratedAudio()
    }

    func updateCueTime(id: UUID, startText: String, endText: String) {
        guard let start = parseTime(startText), let end = parseTime(endText),
              start >= 0, end <= sourceDuration, end - start >= 0.1 else {
            statusMessage = L10n.tr("subdub.subtitle_burn.status.invalid_time")
            return
        }
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index].startTime = start
        cues[index].endTime = end
        selectedCueID = id
        invalidateCue(id)
        persistCues()
    }

    func generateAllAudio() {
        guard requireSubscriptionAccess() else { return }
        startGeneration(for: cues.map(\.id))
    }

    func regenerateCue(_ id: UUID) {
        guard requireSubscriptionAccess() else { return }
        startGeneration(for: [id])
    }

    func importVoiceByPanel() {
        guard hasSource else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard let url = workspace.pickAudioURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importVoice(from: url)
    }

    func handleImportedAudioButton() {
        if hasImportedAudio {
            setPreviewMode(.imported)
        } else {
            importVoiceByPanel()
        }
    }

    func removeImportedAudio() {
        guard let importedAudioURL else { return }
        try? FileManager.default.removeItem(at: importedAudioURL)
        self.importedAudioURL = nil
        importedWaveformSamples = []
        importedWaveformDuration = 0
        if previewMode == .imported {
            previewMode = .original
            reloadPreview()
        }
        statusMessage = L10n.tr("subdub.audio_replacement.status.imported_removed")
    }

    func importVoice(from url: URL) {
        guard hasSource, let sessionDirectory = timelineSession.sessionDirectory else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard !state.isBusy else { return }

        statusMessage = L10n.tr("subdub.status.importing")
        let workspace = self.workspace
        Task { [weak self] in
            guard let self else { return }
            do {
                let persistedURL = try workspace.persistInput(
                    from: url,
                    kind: .audio,
                    sessionDirectory: sessionDirectory
                )
                try await exportService.validateAudio(persistedURL)
                guard !Task.isCancelled else { return }
                if let previousURL = importedAudioURL, previousURL != persistedURL {
                    try? FileManager.default.removeItem(at: previousURL)
                }
                let waveform = await loadWaveform(from: persistedURL)
                importedAudioURL = persistedURL
                importedWaveformSamples = waveform.samples
                importedWaveformDuration = waveform.duration
                previewMode = .imported
                statusMessage = L10n.f("subdub.status.imported", persistedURL.lastPathComponent)
                reloadPreview()
            } catch is CancellationError {
                statusMessage = L10n.tr("subdub.audio_replacement.status.cancelled")
            } catch {
                statusMessage = L10n.f(
                    "subdub.status.import_failed",
                    error.localizedDescription
                )
            }
        }
    }

    func importDroppedVoiceProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let identifiers = [UTType.audio.identifier, UTType.fileURL.identifier]
        guard let identifier = identifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else { return }
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                self?.importVoice(from: url)
            }
        }
    }

    func cancelCurrentTask() {
        activeTask?.cancel()
        activeTask = nil
        state = .ready
        statusMessage = L10n.tr("subdub.audio_replacement.status.cancelled")
        persistManifest()
    }

    func clearReplacementAudio() {
        activeTask?.cancel()
        activeTask = nil
        if let sessionDirectory = timelineSession.sessionDirectory {
            let directory = sessionDirectory.appendingPathComponent(
                "AudioReplacement",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: directory)
        }
        draft = AudioReplacementDraft()
        replacementAudioURL = nil
        importedAudioURL = nil
        replacementWaveformSamples = []
        replacementWaveformDuration = 0
        importedWaveformSamples = []
        importedWaveformDuration = 0
        cueStatuses = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, .pending) })
        previewMode = .original
        state = hasSource ? .ready : .idle
        statusMessage = L10n.tr("subdub.audio_replacement.status.idle")
        reloadPreview()
    }

    func setPreviewMode(_ mode: AudioPreviewMode) {
        guard availablePreviewModes.contains(mode) else { return }
        previewMode = mode
        reloadPreview()
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

    func stopPlayback() {
        player.pause()
        player.seek(to: .zero)
        playbackPosition = 0
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

    func removeVideo() {
        clearReplacementAudio()
        timelineSession.clearProject()
        sourceURL = nil
        sourceDuration = 0
        sourceVideoSize = .zero
        sourceWaveformSamples = []
        cues = []
        selectedCueID = nil
        isPlayerReady = false
        player.replaceCurrentItem(with: nil)
        state = .idle
        statusMessage = L10n.tr("subdub.status.video_removed")
    }

    func exportReplacementVideo() {
        guard requireSubscriptionAccess() else { return }
        guard canExport,
              let sourceURL,
              let exportAudioURL = selectedExportAudioURL,
              let sessionDirectory = timelineSession.sessionDirectory else {
            statusMessage = L10n.tr("subdub.audio_replacement.status.invalid_input")
            return
        }
        do {
            try validateCuesForReplacement()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard let outputURL = workspace.pickVideoOutputURL(
            suggestedName: "\(sourceURL.deletingPathExtension().lastPathComponent)-字幕口播.mp4"
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }

        let exportCues = cues
        let exportDuration = sourceDuration
        let exportStyle = timelineSession.document?.style ?? .standard
        let exportThemeColor = timelineSession.document?.themeColor ?? .white
        state = .exporting
        statusMessage = L10n.tr("subdub.subtitle.status.exporting")
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await exportService.burnSubtitlesAndReplaceAudio(
                    videoURL: sourceURL,
                    audioURL: exportAudioURL,
                    cues: exportCues.map(\.subtitleCue),
                    outputURL: outputURL,
                    duration: exportDuration,
                    sessionDirectory: sessionDirectory,
                    style: exportStyle,
                    themeColor: exportThemeColor
                )
                state = .ready
                statusMessage = L10n.f("subdub.status.exported", outputURL.lastPathComponent)
                workspace.reveal(outputURL)
            } catch is CancellationError {
                state = .ready
                statusMessage = L10n.tr("subdub.audio_replacement.status.cancelled")
            } catch {
                state = .failed
                statusMessage = L10n.f("subdub.status.export_failed", error.localizedDescription)
            }
        }
    }

    func exportAudioReplacement() {
        guard requireSubscriptionAccess() else { return }
        guard canAudioReplaceExport,
              let sourceURL,
              let exportAudioURL = selectedExportAudioURL else {
            statusMessage = L10n.tr("subdub.audio_replacement.status.invalid_input")
            return
        }
        guard let outputURL = workspace.pickVideoOutputURL(
            suggestedName: "\(sourceURL.deletingPathExtension().lastPathComponent)-音频替换.mp4"
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }

        let exportDuration = sourceDuration
        state = .exporting
        statusMessage = L10n.tr("subdub.audio_replacement.status.exporting_audio")
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await exportService.replaceAudio(
                    videoURL: sourceURL,
                    audioURL: exportAudioURL,
                    outputURL: outputURL,
                    duration: exportDuration
                )
                state = .ready
                statusMessage = L10n.f("subdub.status.exported", outputURL.lastPathComponent)
                workspace.reveal(outputURL)
            } catch is CancellationError {
                state = .ready
                statusMessage = L10n.tr("subdub.audio_replacement.status.cancelled")
            } catch {
                state = .failed
                statusMessage = L10n.f("subdub.status.export_failed", error.localizedDescription)
            }
        }
    }

    private var allCuesGenerated: Bool {
        !cues.isEmpty && cues.allSatisfy { cueStatuses[$0.id] == .generated }
    }

    private var selectedExportAudioURL: URL? {
        previewMode == .imported ? importedAudioURL : replacementAudioURL
    }

    private func startGeneration(for ids: [UUID]) {
        guard hasSource, let sessionDirectory = timelineSession.sessionDirectory else {
            statusMessage = L10n.tr("subdub.audio_replacement.status.invalid_input")
            return
        }
        guard !state.isBusy else { return }
        guard !ids.isEmpty else {
            statusMessage = L10n.tr("subdub.audio_replacement.status.invalid_input")
            return
        }
        do {
            try validateCuesForReplacement()
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        activeTask?.cancel()
        let language = languageMode
        let voiceIdentifier = selectedVoiceIdentifier
        let speechRate = rate
        state = .generating
        statusMessage = L10n.tr("subdub.audio_replacement.status.generating")
        activeTask = Task { [weak self] in
            guard let self else { return }
            var failedCount = 0
            do {
                let directory = sessionDirectory.appendingPathComponent(
                    "AudioReplacement",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                for id in ids {
                    try Task.checkCancellation()
                    guard let cue = cues.first(where: { $0.id == id }) else { continue }
                    cueStatuses[id] = .generating
                    do {
                        let locale = resolveLocale(for: cue, mode: language)
                        let resolvedVoice = try resolveVoiceIdentifier(
                            explicitIdentifier: voiceIdentifier,
                            locale: locale
                        )
                        let rawDestination = directory.appendingPathComponent("cue_\(id.uuidString).caf")
                        let rawURL = try await speechService.synthesize(
                            text: cue.text,
                            voiceIdentifier: resolvedVoice,
                            rate: speechRate,
                            outputURL: rawDestination
                        )
                        try Task.checkCancellation()
                        let fittedDestination = directory.appendingPathComponent("fit_\(id.uuidString).wav")
                        try? FileManager.default.removeItem(at: fittedDestination)
                        try await exportService.fitAudioToDuration(
                            sourceURL: rawURL,
                            targetDuration: cue.duration,
                            outputURL: fittedDestination
                        )
                        try Task.checkCancellation()
                        draft.cueAudioURLs[id] = fittedDestination
                        draft.cueSignatures[id] = signature(for: cue)
                        draft.cueStatuses[id] = .generated
                        cueStatuses[id] = .generated
                        persistManifest()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedCount += 1
                        cueStatuses[id] = .failed
                        draft.cueStatuses[id] = .failed
                        persistManifest()
                        statusMessage = L10n.f("subdub.status.tts_failed", error.localizedDescription)
                    }
                }

                guard failedCount == 0 else {
                    state = .failed
                    return
                }
                try await rebuildReplacementAudio(in: directory)
                state = .ready
                statusMessage = L10n.tr("subdub.audio_replacement.status.ready")
                persistManifest()
            } catch is CancellationError {
                state = .ready
                statusMessage = L10n.tr("subdub.audio_replacement.status.cancelled")
            } catch {
                state = .failed
                statusMessage = L10n.f("subdub.status.tts_failed", error.localizedDescription)
            }
        }
    }

    private func rebuildReplacementAudio(in directory: URL) async throws {
        let segments = cues.compactMap { cue -> AudioReplacementSegment? in
            guard cueStatuses[cue.id] == .generated,
                  let audioURL = draft.cueAudioURLs[cue.id] else { return nil }
            return AudioReplacementSegment(
                id: cue.id,
                audioURL: audioURL,
                startTime: cue.startTime,
                endTime: cue.endTime
            )
        }
        guard segments.count == cues.count else {
            throw SubDubError.audioReplacementMixFailed(
                L10n.tr("subdub.audio_replacement.status.invalid_input")
            )
        }
        state = .mixing
        statusMessage = L10n.tr("subdub.audio_replacement.status.mixing")
        let outputURL = directory.appendingPathComponent("replacement_audio.m4a")
        try await exportService.makeAudioReplacementMixdown(
            segments: segments,
            duration: sourceDuration,
            outputURL: outputURL
        )
        draft.replacementAudioURL = outputURL
        replacementAudioURL = outputURL
        let waveform = await loadWaveform(from: outputURL)
        replacementWaveformSamples = waveform.samples
        replacementWaveformDuration = waveform.duration
        persistManifest()
        if previewMode == .replacement {
            reloadPreview()
        }
    }

    private func syncFromSession() {
        let newSourceURL = timelineSession.videoURL
        let sourceChanged = sourceURL != newSourceURL
        sourceURL = newSourceURL
        sourceDuration = timelineSession.sourceDuration
        sourceWaveformSamples = timelineSession.sourceWaveformSamples

        if sourceChanged {
            clearRuntimeAudioState()
            restoreManifestIfPresent()
            if let newSourceURL {
                statusMessage = L10n.f("subdub.status.imported", newSourceURL.lastPathComponent)
                loadVideoMetadata(from: newSourceURL)
            } else {
                statusMessage = L10n.tr("subdub.audio_replacement.status.idle")
            }
            reloadPreview()
        }

        guard let document = timelineSession.document else {
            if !cues.isEmpty {
                cues = []
                selectedCueID = nil
                cueStatuses = [:]
            }
            return
        }

        if cues != document.cues {
            cues = document.cues
            selectedCueID = selectedCueID.flatMap { id in
                cues.contains(where: { $0.id == id }) ? id : cues.first?.id
            } ?? cues.first?.id
            synchronizeCueStatuses()
        }
        if !hasSource {
            state = .idle
        } else if state == .idle {
            state = .ready
        }
    }

    private func synchronizeCueStatuses() {
        var nextStatuses: [UUID: AudioReplacementCueStatus] = [:]
        var nextURLs: [UUID: URL] = [:]
        var nextSignatures: [UUID: String] = [:]
        for cue in cues {
            let signature = signature(for: cue)
            nextSignatures[cue.id] = signature
            if draft.cueSignatures[cue.id] == signature,
               let url = draft.cueAudioURLs[cue.id],
               FileManager.default.fileExists(atPath: url.path) {
                nextStatuses[cue.id] = draft.cueStatuses[cue.id] ?? .generated
                nextURLs[cue.id] = url
            } else {
                nextStatuses[cue.id] = .pending
            }
        }
        draft.cueSignatures = nextSignatures
        draft.cueAudioURLs = nextURLs
        draft.cueStatuses = nextStatuses
        cueStatuses = nextStatuses
        if !allCuesGenerated {
            replacementAudioURL = nil
            draft.replacementAudioURL = nil
            replacementWaveformSamples = []
            replacementWaveformDuration = 0
            if previewMode == .replacement {
                previewMode = .original
                reloadPreview()
            }
        }
        persistManifest()
    }

    private func invalidateCue(_ id: UUID) {
        draft.cueAudioURLs[id] = nil
        draft.cueSignatures[id] = nil
        draft.cueStatuses[id] = .pending
        cueStatuses[id] = .pending
        replacementAudioURL = nil
        draft.replacementAudioURL = nil
        replacementWaveformSamples = []
        replacementWaveformDuration = 0
        if previewMode == .replacement {
            previewMode = .original
            reloadPreview()
        }
        persistManifest()
    }

    private func clearRuntimeAudioState() {
        activeTask?.cancel()
        activeTask = nil
        draft = AudioReplacementDraft()
        replacementAudioURL = nil
        importedAudioURL = nil
        replacementWaveformSamples = []
        replacementWaveformDuration = 0
        importedWaveformSamples = []
        importedWaveformDuration = 0
        cueStatuses = [:]
        previewMode = .original
        state = .idle
        isPlayerReady = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackPosition = 0
    }

    private func invalidateGeneratedAudio() {
        let hadGeneratedAudio = cueStatuses.values.contains { $0 == .generated }
        guard hadGeneratedAudio || replacementAudioURL != nil else {
            persistManifest()
            return
        }

        for url in draft.cueAudioURLs.values {
            try? FileManager.default.removeItem(at: url)
            let rawURL = url.deletingLastPathComponent()
                .appendingPathComponent("cue_\(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "fit_", with: "")).caf")
            try? FileManager.default.removeItem(at: rawURL)
        }
        if let replacementAudioURL {
            try? FileManager.default.removeItem(at: replacementAudioURL)
        }
        draft.cueAudioURLs.removeAll()
        draft.cueSignatures.removeAll()
        draft.cueStatuses = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, .pending) })
        cueStatuses = draft.cueStatuses
        draft.replacementAudioURL = nil
        replacementAudioURL = nil
        replacementWaveformSamples = []
        replacementWaveformDuration = 0
        if previewMode == .replacement {
            previewMode = .original
            reloadPreview()
        }
        state = hasSource ? .ready : .idle
        persistManifest()
    }

    private func restoreManifestIfPresent() {
        guard let sessionDirectory = timelineSession.sessionDirectory else { return }
        let directory = sessionDirectory.appendingPathComponent(
            "AudioReplacement",
            isDirectory: true
        )
        let manifestURL = directory.appendingPathComponent("AudioReplacement.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            draft.languageMode = languageMode
            draft.voiceIdentifier = selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
            draft.rate = rate
            return
        }

        do {
            let manifest = try JSONDecoder().decode(AudioReplacementManifest.self, from: data)
            guard manifest.schemaVersion == 1 else { return }
            languageMode = manifest.languageMode
            selectedVoiceIdentifier = manifest.voiceIdentifier ?? ""
            rate = min(max(manifest.rate, 0.5), 2.0)
            draft.languageMode = languageMode
            draft.voiceIdentifier = selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
            draft.rate = rate

            var restoredStatuses: [UUID: AudioReplacementCueStatus] = [:]
            for cue in manifest.cues {
                guard let fileName = cue.audioFileName else { continue }
                let audioURL = directory.appendingPathComponent(fileName).standardizedFileURL
                guard audioURL.deletingLastPathComponent() == directory.standardizedFileURL,
                      FileManager.default.fileExists(atPath: audioURL.path) else { continue }
                draft.cueAudioURLs[cue.id] = audioURL
                draft.cueSignatures[cue.id] = cue.signature
                draft.cueStatuses[cue.id] = cue.status
                restoredStatuses[cue.id] = cue.status
            }
            cueStatuses = restoredStatuses

            if let fileName = manifest.replacementAudioFileName {
                let audioURL = directory.appendingPathComponent(fileName).standardizedFileURL
                if audioURL.deletingLastPathComponent() == directory.standardizedFileURL,
                   FileManager.default.fileExists(atPath: audioURL.path) {
                    replacementAudioURL = audioURL
                    draft.replacementAudioURL = audioURL
                    Task { [weak self] in
                        guard let self else { return }
                        let waveform = await loadWaveform(from: audioURL)
                        guard replacementAudioURL == audioURL else { return }
                        replacementWaveformSamples = waveform.samples
                        replacementWaveformDuration = waveform.duration
                    }
                }
            }
        } catch {
            statusMessage = L10n.f(
                "subdub.error.audio_replacement_validation_failed",
                error.localizedDescription
            )
        }
    }

    private func persistManifest() {
        guard let sessionDirectory = timelineSession.sessionDirectory else { return }
        let directory = sessionDirectory.appendingPathComponent(
            "AudioReplacement",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let manifest = AudioReplacementManifest(
                languageMode: languageMode,
                voiceIdentifier: selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier,
                rate: rate,
                replacementAudioFileName: replacementAudioURL?.lastPathComponent,
                cues: cues.map { cue in
                    AudioReplacementManifest.Cue(
                        id: cue.id,
                        status: cueStatuses[cue.id] ?? .pending,
                        signature: signature(for: cue),
                        audioFileName: draft.cueAudioURLs[cue.id]?.lastPathComponent
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: directory.appendingPathComponent("AudioReplacement.json"),
                options: .atomic
            )
        } catch {
            statusMessage = L10n.f(
                "subdub.error.audio_replacement_validation_failed",
                error.localizedDescription
            )
        }
    }

    private func persistCues() {
        guard sourceDuration > 0 else { return }
        do {
            try timelineSession.updateDocument(
                SubtitleTimelineDocument(
                    sourceDuration: sourceDuration,
                    style: timelineSession.document?.style ?? .standard,
                    themeColor: timelineSession.document?.themeColor ?? .white,
                    cues: cues
                )
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadVideoMetadata(from url: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await AVAssetAsyncLoaders.firstTrack(
                    in: asset,
                    mediaType: .video
                ) else { return }
                sourceVideoSize = try await AVAssetAsyncLoaders.orientedSize(of: track)
            } catch {
                sourceVideoSize = .zero
            }
        }
    }

    private func reloadPreview() {
        previewTask?.cancel()
        guard let sourceURL else {
            isPlayerReady = false
            return
        }
        let mode = previewMode
        let replacementURL = replacementAudioURL
        let importedURL = importedAudioURL
        let position = playbackPosition
        let wasPlaying = player.timeControlStatus == .playing
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await previewService.makeItem(
                    videoURL: sourceURL,
                    replacementAudioURL: mode == .replacement
                        ? replacementURL
                        : (mode == .imported ? importedURL : nil)
                )
                guard !Task.isCancelled else { return }
                player.pause()
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                isPlayerReady = true
                if wasPlaying { player.play() }
            } catch {
                isPlayerReady = false
                statusMessage = L10n.f(
                    "subdub.error.audio_replacement_validation_failed",
                    error.localizedDescription
                )
            }
        }
    }

    private var overlayWaveformMode: AudioPreviewMode? {
        switch previewMode {
        case .replacement where !replacementWaveformSamples.isEmpty:
            return .replacement
        case .imported where !importedWaveformSamples.isEmpty:
            return .imported
        case .original:
            if !replacementWaveformSamples.isEmpty { return .replacement }
            if !importedWaveformSamples.isEmpty { return .imported }
        case .replacement:
            if !importedWaveformSamples.isEmpty { return .imported }
        case .imported:
            if !replacementWaveformSamples.isEmpty { return .replacement }
        }
        return nil
    }

    private func loadWaveform(from url: URL) async -> (samples: [Double], duration: Double) {
        do {
            let samples = try await waveformService.samples(from: url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return (samples, 0) }
            return (samples, duration)
        } catch {
            return ([], 0)
        }
    }

    private func resolveVoiceIdentifier(
        explicitIdentifier: String,
        locale: String
    ) throws -> String {
        if !explicitIdentifier.isEmpty {
            guard AVSpeechSynthesisVoice(identifier: explicitIdentifier) != nil else {
                throw SubDubError.speechVoiceMissing
            }
            return explicitIdentifier
        }
        guard let voice = speechService.availableVoices(for: locale).first else {
            throw SubDubError.speechVoiceMissing
        }
        return voice.identifier
    }

    private func resolveLocale(
        for cue: SubtitleTimelineCue,
        mode: AudioReplacementLanguageMode
    ) -> String {
        if let locale = mode.localeIdentifier { return locale }
        return cue.text.range(of: "[\\p{Han}]", options: .regularExpression) != nil
            ? "zh-CN"
            : "en-US"
    }

    private func validateCuesForReplacement() throws {
        guard hasSource, !cues.isEmpty else {
            throw SubDubError.audioReplacementValidationFailed(
                L10n.tr("subdub.audio_replacement.status.invalid_input")
            )
        }
        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        var previousEnd = 0.0
        for cue in sortedCues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  text != L10n.tr("subdub.subtitle_burn.default_text"),
                  cue.startTime >= 0,
                  cue.endTime <= sourceDuration,
                  cue.endTime - cue.startTime >= 0.1 else {
                throw SubDubError.audioReplacementValidationFailed(
                    L10n.tr("subdub.subtitle_burn.status.invalid_cue")
                )
            }
            guard cue.startTime >= previousEnd else {
                throw SubDubError.audioReplacementTiming(
                    L10n.tr("subdub.subtitle_burn.status.invalid_time")
                )
            }
            previousEnd = cue.endTime
        }
    }

    private func signature(for cue: SubtitleTimelineCue) -> String {
        "\(cue.id.uuidString)|\(cue.startTime)|\(cue.endTime)|\(cue.text)"
    }

    private func invalidateCueStatusText(_ status: AudioReplacementCueStatus) -> String {
        switch status {
        case .pending: return L10n.tr("subdub.audio_replacement.cue.pending")
        case .generating: return L10n.tr("subdub.audio_replacement.cue.generating")
        case .generated: return L10n.tr("subdub.audio_replacement.cue.generated")
        case .failed: return L10n.tr("subdub.audio_replacement.cue.failed")
        }
    }

    func cueStatusText(for id: UUID) -> String {
        invalidateCueStatusText(cueStatuses[id] ?? .pending)
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
            statusMessage = L10n.tr("subscription.lock.subdub_audio_replacement")
            onRequireSubscription?()
            return false
        }
        return true
    }
}

private func formatSubtitleTime(_ seconds: Double) -> String {
    let totalMilliseconds = max(0, Int((seconds * 1_000).rounded()))
    let milliseconds = totalMilliseconds % 1_000
    let totalSeconds = totalMilliseconds / 1_000
    let secondsPart = totalSeconds % 60
    let minutes = totalSeconds / 60
    return String(format: "%02d:%02d.%03d", minutes, secondsPart, milliseconds)
}
