import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SubtitleSyncViewModel: ObservableObject {
    @Published private(set) var videoURL: URL?
    @Published private(set) var audioURL: URL?
    @Published private(set) var subtitleURL: URL?
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var exportURL: URL?
    @Published private(set) var state: SubDubSessionState = .idle
    @Published private(set) var statusMessage: String = L10n.tr("subdub.subtitle.status.idle")
    @Published private(set) var isPlayerReady = false

    let player = AVPlayer()

    private let workspace = SubDubWorkspaceService()
    private let parser: SubtitleParser = SRTVTTSubtitleParser()
    private let exportService = SubDubExportService()
    private var sessionDirectory: URL?
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?

    var canExport: Bool {
        videoURL != nil && audioURL != nil && !cues.isEmpty && sourceDuration > 0 && !state.isBusy
    }

    var inputSummary: String {
        let video = videoURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video")
        let audio = audioURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_audio")
        let subtitle = subtitleURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_subtitle")
        return L10n.f("subdub.subtitle.summary", video, audio, subtitle, cues.count)
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

    func importAudioByPanel() {
        guard let url = workspace.pickAudioURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importAudio(from: url)
    }

    func importSubtitleByPanel() {
        guard let url = workspace.pickSubtitleURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importSubtitle(from: url)
    }

    func importVideo(from url: URL) {
        Task { await loadVideo(from: url) }
    }

    func importAudio(from url: URL) {
        Task { await loadAudio(from: url) }
    }

    func importSubtitle(from url: URL) {
        Task { await loadSubtitle(from: url) }
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let candidates = [UTType.movie.identifier, UTType.audio.identifier, UTType.plainText.identifier, UTType.fileURL.identifier]
        guard let identifier = candidates.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return }
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                let ext = url.pathExtension.lowercased()
                if ["srt", "vtt"].contains(ext) {
                    self?.importSubtitle(from: url)
                } else if ["mp3", "aac", "wav", "m4a"].contains(ext) {
                    self?.importAudio(from: url)
                } else {
                    self?.importVideo(from: url)
                }
            }
        }
    }

    func export() {
        guard requireSubscriptionAccess() else { return }
        guard let videoURL, let audioURL, !cues.isEmpty, sourceDuration > 0 else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard cues.allSatisfy({ $0.start.seconds >= 0 && $0.end.seconds <= sourceDuration + 0.01 }) else {
            statusMessage = L10n.f(
                "subdub.error.subtitle_validation",
                L10n.tr("subdub.error.subtitle_out_of_range")
            )
            return
        }
        guard let sessionDirectory else {
            statusMessage = L10n.tr("subdub.error.output_unavailable")
            return
        }
        guard let outputURL = workspace.pickVideoOutputURL(
            suggestedName: "\(videoURL.deletingPathExtension().lastPathComponent)-字幕同步.mp4"
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }
        state = .exporting
        statusMessage = L10n.tr("subdub.subtitle.status.exporting")
        Task {
            do {
                try await exportService.burnSubtitlesAndReplaceAudio(
                    videoURL: videoURL,
                    audioURL: audioURL,
                    cues: cues,
                    outputURL: outputURL,
                    duration: sourceDuration,
                    sessionDirectory: sessionDirectory
                )
                exportURL = outputURL
                state = .succeeded
                statusMessage = L10n.f("subdub.status.exported", outputURL.lastPathComponent)
                workspace.reveal(outputURL)
            } catch {
                state = .failed
                statusMessage = L10n.f("subdub.status.export_failed", error.localizedDescription)
            }
        }
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            statusMessage = L10n.tr("subdub.subtitle.status.paused")
        } else {
            player.play()
            statusMessage = L10n.tr("subdub.subtitle.status.playing")
        }
    }

    private func loadVideo(from url: URL) async {
        state = .preparing
        statusMessage = L10n.tr("subdub.status.importing")
        do {
            let session = try sessionDirectory ?? workspace.makeSessionDirectory()
            let persistedURL = try workspace.persistInput(from: url, kind: .video, sessionDirectory: session)
            let asset = AVURLAsset(url: persistedURL)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0, try await asset.loadTracks(withMediaType: .video).isEmpty == false else {
                throw SubDubError.videoValidationFailed
            }
            sessionDirectory = session
            videoURL = persistedURL
            sourceDuration = duration.seconds
            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            await player.seek(to: .zero)
            isPlayerReady = true
            state = .ready
            statusMessage = L10n.f("subdub.status.imported", persistedURL.lastPathComponent)
            validateCueRangeIfPossible()
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func loadAudio(from url: URL) async {
        do {
            let session = try sessionDirectory ?? workspace.makeSessionDirectory()
            let persistedURL = try workspace.persistInput(from: url, kind: .audio, sessionDirectory: session)
            try await exportService.validateAudio(persistedURL)
            sessionDirectory = session
            audioURL = persistedURL
            statusMessage = L10n.f("subdub.status.audio_imported", persistedURL.lastPathComponent)
        } catch {
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func loadSubtitle(from url: URL) async {
        do {
            let session = try sessionDirectory ?? workspace.makeSessionDirectory()
            let persistedURL = try workspace.persistInput(from: url, kind: .subtitle, sessionDirectory: session)
            let parsed = try parser.parse(url: persistedURL)
            sessionDirectory = session
            subtitleURL = persistedURL
            cues = parsed
            statusMessage = L10n.f("subdub.status.subtitle_imported", persistedURL.lastPathComponent)
            validateCueRangeIfPossible()
        } catch {
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func validateCueRangeIfPossible() {
        guard sourceDuration > 0, !cues.isEmpty else { return }
        if cues.contains(where: { $0.start.seconds < 0 || $0.end.seconds > sourceDuration + 0.01 }) {
            statusMessage = L10n.f(
                "subdub.error.subtitle_validation",
                L10n.tr("subdub.error.subtitle_out_of_range")
            )
        }
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_subtitle")
            onRequireSubscription?()
            return false
        }
        return true
    }
}
