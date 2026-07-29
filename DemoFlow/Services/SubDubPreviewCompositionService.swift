import AVFoundation

struct SubDubPreviewCompositionService {
    func makeItem(videoURL: URL, replacementAudioURL: URL?) async throws -> AVPlayerItem {
        guard let replacementAudioURL else {
            return AVPlayerItem(url: videoURL)
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: replacementAudioURL)
        guard let videoTrack = try await AVAssetAsyncLoaders.firstTrack(
            in: videoAsset,
            mediaType: .video
        ), let audioTrack = try await AVAssetAsyncLoaders.firstTrack(
            in: audioAsset,
            mediaType: .audio
        ) else {
            throw SubDubError.audioReplacementValidationFailed(
                L10n.tr("subdub.error.video_validation")
            )
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        guard videoDuration.seconds > 0, audioDuration.seconds > 0 else {
            throw SubDubError.audioReplacementValidationFailed(
                L10n.tr("subdub.error.audio_validation")
            )
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SubDubError.audioReplacementValidationFailed(
                L10n.tr("subdub.error.output_unavailable")
            )
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(
                start: .zero,
                duration: min(videoDuration, audioDuration)
            ),
            of: audioTrack,
            at: .zero
        )
        return AVPlayerItem(asset: composition)
    }
}
