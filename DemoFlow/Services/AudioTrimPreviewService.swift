//
//  AudioTrimPreviewService.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import AVFoundation
import Foundation

@MainActor
final class AudioTrimPreviewService: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var progressHandler: ((TimeInterval) -> Void)?
    private var finishHandler: (() -> Void)?
    private var cleanupURL: URL?

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    func play(
        url: URL,
        startTime: TimeInterval,
        onProgress: @escaping (TimeInterval) -> Void,
        onFinish: @escaping () -> Void
    ) throws {
        stop()

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.currentTime = min(max(startTime, 0), player.duration)
        player.prepareToPlay()
        player.play()

        self.player = player
        self.progressHandler = onProgress
        self.finishHandler = onFinish
        self.cleanupURL = url.path.contains("demoflow-audio-trim-preview") ? url : nil
        startProgressTimer()
        onProgress(player.currentTime)
    }

    func resume() {
        guard let player else { return }
        player.play()
        startProgressTimer()
    }

    func pause() {
        player?.pause()
        stopProgressTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        progressHandler = nil
        finishHandler = nil
        stopProgressTimer()
        cleanupPreviewFileIfNeeded()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopProgressTimer()
        progressHandler?(player.duration)
        finishHandler?()
        self.player = nil
        progressHandler = nil
        finishHandler = nil
        cleanupPreviewFileIfNeeded()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let reportProgress: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, let player = self.player else { return }
            self.progressHandler?(player.currentTime)
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                reportProgress()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func cleanupPreviewFileIfNeeded() {
        guard let cleanupURL else { return }
        try? FileManager.default.removeItem(at: cleanupURL)
        self.cleanupURL = nil
    }
}
