import AVFoundation
import CoreGraphics
import Foundation

struct VideoTimelineCompositionService {
    private let ffmpegEngine = VideoCuttingFFmpegExportEngine()
    private let avFoundationEngine = VideoCuttingComposeExportEngine()

    func makePreviewItem(
        clips: [VideoTimelineClip],
        clipStartSeconds: [Double] = []
    ) async throws -> AVPlayerItem {
        guard !clips.isEmpty else { throw VideoCompositionError.emptyTimeline }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoCompositionError.exportFailed("video composition track unavailable")
        }

        let hasAudio = clips.contains(where: \.hasAudioTrack)
        let audioTrack = hasAudio
            ? composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            : nil

        var cursor = CMTime.zero
        for (index, clip) in clips.enumerated() {
            let asset = AVAssetAsyncLoaders.makeURLAsset(clip.sourceURL)
            guard let sourceVideo = try await AVAssetAsyncLoaders.firstTrack(
                in: asset,
                mediaType: .video
            ) else {
                throw VideoCompositionError.invalidVideo
            }

            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: clip.durationSeconds, preferredTimescale: 600)
            )
            let requestedStart = clipStartSeconds.indices.contains(index)
                ? max(0, clipStartSeconds[index])
                : cursor.seconds
            let timelineStart = CMTime(seconds: max(cursor.seconds, requestedStart), preferredTimescale: 600)
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: timelineStart)

            if clip.hasAudioTrack,
               let sourceAudio = try await AVAssetAsyncLoaders.firstTrack(
                   in: asset,
                   mediaType: .audio
               ) {
                try audioTrack?.insertTimeRange(range, of: sourceAudio, at: timelineStart)
            }
            cursor = max(cursor, timelineStart + range.duration)
        }

        return AVPlayerItem(asset: composition)
    }

    func export(
        project: VideoTimelineCompositionProject,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        guard !project.clips.isEmpty else { throw VideoCompositionError.emptyTimeline }
        let starts = project.clips.indices.map { index in
            max(0, project.clipStartSeconds.indices.contains(index) ? project.clipStartSeconds[index] : 0)
        }

        let ffmpegProject = VideoTimelineFFmpegProject(
            clips: project.clips,
            clipStartSeconds: starts,
            cropRectNormalized: .full,
            renderSize: project.renderSize,
            audioProcessingConfig: .default,
            isAudioMuted: false,
            outputURL: project.outputURL,
            performanceProfile: .quality,
            frameRate: project.frameRate
        )

        do {
            return try await ffmpegEngine.exportTimeline(project: ffmpegProject, onProgress: onProgress)
        } catch {
            do {
                return try await avFoundationEngine.exportTimeline(project: ffmpegProject)
            } catch {
                throw VideoCompositionError.exportFailed(error.localizedDescription)
            }
        }
    }

    /// Encodes a still image as a short, silent H.264 MP4 so it can participate
    /// in the same timeline model as ordinary video clips.
    func makeStillVideo(
        from image: CGImage,
        renderSize: CGSize,
        frameRate: Double,
        duration: Double,
        outputURL: URL
    ) async throws -> URL {
        let width = max(2, Int(renderSize.width.rounded()) / 2 * 2)
        let height = max(2, Int(renderSize.height.rounded()) / 2 * 2)
        let fps = max(1, min(Int(frameRate.rounded()), 60))
        let frameCount = max(1, Int((duration * Double(fps)).rounded(.up)))

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoExpectedSourceFrameRateKey: fps
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw VideoCompositionError.exportFailed("cover video input unavailable")
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.startWriting() else {
            throw VideoCompositionError.exportFailed(writer.error?.localizedDescription ?? "cover writer could not start")
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool,
                  let pixelBuffer = makePixelBuffer(
                      from: image,
                      width: width,
                      height: height,
                      pool: pool
                  ) else {
                writer.cancelWriting()
                throw VideoCompositionError.exportFailed("cover frame could not be encoded")
            }
            let timestamp = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: timestamp) else {
                writer.cancelWriting()
                throw VideoCompositionError.exportFailed(writer.error?.localizedDescription ?? "cover frame append failed")
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VideoCompositionError.exportFailed(writer.error?.localizedDescription ?? "cover video could not be completed")
        }
        return outputURL
    }

    private func makePixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let target = AVMakeRect(
            aspectRatio: CGSize(width: image.width, height: image.height),
            insideRect: CGRect(x: 0, y: 0, width: width, height: height)
        )
        // The Core Video BGRA bitmap context and CGImage both use top-left image
        // coordinates here.  AVAssetImageGenerator has already applied a source
        // video's preferred transform, so a further flip would invert both video
        // frame and imported-image covers.
        context.draw(image, in: target)
        return pixelBuffer
    }
}
