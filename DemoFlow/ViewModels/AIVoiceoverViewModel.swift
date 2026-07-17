import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AIVoiceoverViewModel: ObservableObject {
    @Published var text = ""
    @Published var apiKeyDraft = ""
    @Published var selectedVoice = "alloy"
    @Published var speed = 1.0
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDuration: Double = 0
    @Published private(set) var generatedAudioURL: URL?
    @Published private(set) var exportURL: URL?
    @Published private(set) var state: SubDubSessionState = .idle
    @Published private(set) var statusMessage: String = L10n.tr("subdub.ai.status.idle")
    @Published private(set) var playbackPosition: Double = 0
    @Published private(set) var isPlayerReady = false
    @Published private(set) var isAudioPlaying = false

    let player = AVPlayer()

    private let workspace = SubDubWorkspaceService()
    private let exportService = SubDubExportService()
    private let ttsService: OpenAITTSService
    private var sessionDirectory: URL?
    private var timeObserverToken: Any?
    private var audioPlayer: AVAudioPlayer?
    private weak var subscriptionViewModel: SubscriptionViewModel?
    private var onRequireSubscription: (() -> Void)?

    init() {
        ttsService = OpenAITTSService()
        apiKeyDraft = ""
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.playbackPosition = max(0, time.seconds)
            }
        }
    }

    deinit {
        if let timeObserverToken { player.removeTimeObserver(timeObserverToken) }
    }

    var hasAPIKey: Bool { ttsService.hasAPIKey }
    var hasGeneratedAudio: Bool { generatedAudioURL != nil }
    var sourceName: String { sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video") }

    func configureSubscriptionAccess(
        subscriptionViewModel: SubscriptionViewModel,
        onRequireSubscription: @escaping () -> Void
    ) {
        self.subscriptionViewModel = subscriptionViewModel
        self.onRequireSubscription = onRequireSubscription
    }

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = L10n.tr("subdub.ai.status.api_key_empty")
            return
        }
        guard ttsService.saveAPIKey(trimmed) else {
            statusMessage = L10n.tr("subdub.ai.status.api_key_failed")
            return
        }
        apiKeyDraft = ""
        statusMessage = L10n.tr("subdub.ai.status.api_key_saved")
    }

    func importVideoByPanel() {
        guard let url = workspace.pickVideoURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        importVideo(from: url)
    }

    func importTextByPanel() {
        guard let url = workspace.pickTextURL() else {
            statusMessage = L10n.tr("subdub.status.import_cancelled")
            return
        }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            statusMessage = L10n.f("subdub.status.text_imported", url.lastPathComponent)
        } catch {
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    func importVideo(from url: URL) {
        Task { await loadVideo(from: url) }
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        let identifier = workspace.videoTypes.map(\.identifier).first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) ?? UTType.fileURL.identifier
        provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, _ in
            guard let url else { return }
            DispatchQueue.main.async { self?.importVideo(from: url) }
        }
    }

    func generateTTS() {
        guard requireSubscriptionAccess() else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = L10n.tr("subdub.error.empty_text")
            return
        }
        state = .preparing
        statusMessage = L10n.tr("subdub.ai.status.generating")
        Task {
            do {
                let generatedURL = try await ttsService.synthesize(
                    request: SubDubTTSRequest(text: text, voice: selectedVoice, speed: speed)
                )
                let session = try sessionDirectory ?? workspace.makeSessionDirectory()
                sessionDirectory = session
                let audioDirectory = session.appendingPathComponent("Audio", isDirectory: true)
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                let destination = audioDirectory.appendingPathComponent("voiceover.mp3")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: generatedURL, to: destination)
                try await exportService.validateAudio(destination)
                generatedAudioURL = destination
                state = .finished
                statusMessage = L10n.tr("subdub.ai.status.ready")
            } catch {
                state = .failed
                statusMessage = L10n.f("subdub.status.tts_failed", error.localizedDescription)
            }
        }
    }

    func saveMP3() {
        guard requireSubscriptionAccess() else { return }
        guard let generatedAudioURL else {
            statusMessage = L10n.tr("subdub.error.audio_validation")
            return
        }
        guard let outputURL = workspace.pickAudioOutputURL(
            suggestedName: "voiceover.mp3",
            contentType: .mp3
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: generatedAudioURL, to: outputURL)
            statusMessage = L10n.f("subdub.status.audio_saved", outputURL.lastPathComponent)
            workspace.reveal(outputURL)
        } catch {
            statusMessage = L10n.f("subdub.status.save_failed", error.localizedDescription)
        }
    }

    func mergeVideo() {
        guard requireSubscriptionAccess() else { return }
        guard let sourceURL, let generatedAudioURL, sourceDuration > 0 else {
            statusMessage = L10n.tr("subdub.error.input_missing")
            return
        }
        guard let outputURL = workspace.pickVideoOutputURL(
            suggestedName: "\(sourceURL.deletingPathExtension().lastPathComponent)-口播.mp4"
        ) else {
            statusMessage = L10n.tr("subdub.status.save_cancelled")
            return
        }
        state = .exporting
        statusMessage = L10n.tr("subdub.ai.status.exporting")
        Task {
            do {
                try await exportService.replaceAudio(
                    videoURL: sourceURL,
                    audioURL: generatedAudioURL,
                    outputURL: outputURL,
                    duration: sourceDuration
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
            statusMessage = L10n.tr("subdub.ai.status.paused")
        } else {
            player.play()
            statusMessage = L10n.tr("subdub.ai.status.playing")
        }
    }

    func toggleAudioPreview() {
        guard let generatedAudioURL else { return }
        if isAudioPlaying {
            audioPlayer?.stop()
            isAudioPlaying = false
            statusMessage = L10n.tr("subdub.ai.status.audio_paused")
            return
        }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: generatedAudioURL)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isAudioPlaying = true
            statusMessage = L10n.tr("subdub.ai.status.audio_playing")
        } catch {
            statusMessage = L10n.f("subdub.status.audio_invalid", error.localizedDescription)
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
            sourceURL = persistedURL
            sourceDuration = duration.seconds
            playbackPosition = 0
            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            await player.seek(to: .zero)
            isPlayerReady = true
            state = generatedAudioURL == nil ? .ready : .finished
            statusMessage = L10n.f("subdub.status.imported", persistedURL.lastPathComponent)
        } catch {
            state = .failed
            statusMessage = L10n.f("subdub.status.import_failed", error.localizedDescription)
        }
    }

    private func requireSubscriptionAccess() -> Bool {
        guard subscriptionViewModel?.isProUnlocked == true else {
            statusMessage = L10n.tr("subscription.lock.subdub_ai")
            onRequireSubscription?()
            return false
        }
        return true
    }
}
