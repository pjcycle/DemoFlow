//
//  PiPFrameProcessingEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Vision

final class PiPFrameProcessingEngine {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var processingConfig: PiPProcessingConfig = .default
    private var aspectRatio: PiPAspectRatio = .sixteenByNine

    private var smoothedFramingRect: CGRect?
    private var lastDetectedFaceRect: CGRect?
    private var lastDetectionSeconds: Double = -.greatestFiniteMagnitude
    private var lastKeyframeSeconds: Double = -.greatestFiniteMagnitude

    func configure(
        processingConfig: PiPProcessingConfig,
        aspectRatio: PiPAspectRatio
    ) {
        self.processingConfig = processingConfig
        self.aspectRatio = aspectRatio
    }

    func reset() {
        smoothedFramingRect = nil
        lastDetectedFaceRect = nil
        lastDetectionSeconds = -.greatestFiniteMagnitude
        lastKeyframeSeconds = -.greatestFiniteMagnitude
    }

    func processFrame(from sampleBuffer: CMSampleBuffer) -> FrameResult? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let seconds = max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)

        let faceRect = detectFaceIfNeeded(pixelBuffer: pixelBuffer, seconds: seconds)
        let framingRect = resolvedFramingRect(faceRect: faceRect)

        guard let previewImage = renderPreviewImage(
            from: pixelBuffer,
            framingRect: framingRect
        ) else { return nil }

        var keyframe: FaceFramingKeyframe?
        if processingConfig.faceFramingEnabled,
           let framingRect,
           (seconds - lastKeyframeSeconds) >= 0.10 {
            keyframe = FaceFramingKeyframe(
                seconds: seconds,
                normalizedRect: framingRect
            )
            lastKeyframeSeconds = seconds
        }

        return FrameResult(
            previewImage: previewImage,
            framingRect: framingRect,
            keyframe: keyframe
        )
    }

    func processAssetForKeyframes(cameraURL: URL) async -> [FaceFramingKeyframe] {
        let asset = AVURLAsset(url: cameraURL)
        let videoTrack: AVAssetTrack
        do {
            videoTrack = try await loadFirstVideoTrack(from: asset)
        } catch {
            return []
        }

        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                return []
            }
            reader.add(output)
            guard reader.startReading() else {
                return []
            }

            reset()
            var keyframes: [FaceFramingKeyframe] = []
            while reader.status == .reading {
                guard let buffer = output.copyNextSampleBuffer() else { break }
                if let result = processFrame(from: buffer), let keyframe = result.keyframe {
                    keyframes.append(keyframe)
                }
            }
            if reader.status == .completed {
                return keyframes
            }
            return keyframes
        } catch {
            return []
        }
    }

    private func loadFirstVideoTrack(from asset: AVAsset) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let loadedTrack = tracks.first else {
            throw NSError(domain: "DemoFlow.PiPFrameProcessingEngine", code: 1)
        }
        return loadedTrack
    }

    private func detectFaceIfNeeded(
        pixelBuffer: CVPixelBuffer,
        seconds: Double
    ) -> CGRect? {
        guard processingConfig.faceFramingEnabled else { return nil }
        if (seconds - lastDetectionSeconds) < 0.15 {
            return lastDetectedFaceRect
        }
        lastDetectionSeconds = seconds

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return lastDetectedFaceRect
        }

        let faces = request.results ?? []
        let largestFace = faces.max { lhs, rhs in
            (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
        }
        lastDetectedFaceRect = largestFace?.boundingBox.standardized
        return lastDetectedFaceRect
    }

    private func resolvedFramingRect(faceRect: CGRect?) -> CGRect? {
        guard processingConfig.faceFramingEnabled else { return nil }
        guard let faceRect else {
            smoothedFramingRect = nil
            return nil
        }

        let scale = recommendedCropScale(for: faceRect)
        let target = makeFramingRect(
            centeredAt: CGPoint(x: faceRect.midX, y: faceRect.midY),
            scale: scale
        )

        if let smoothedFramingRect {
            let alpha = processingConfig.clampedSmoothing
            let mixed = interpolate(from: smoothedFramingRect, to: target, progress: alpha)
            self.smoothedFramingRect = clampNormalized(mixed)
        } else {
            smoothedFramingRect = clampNormalized(target)
        }
        return smoothedFramingRect
    }

    private func recommendedCropScale(for faceRect: CGRect) -> Double {
        let faceScale = max(faceRect.width, faceRect.height)
        guard faceScale > 0 else { return processingConfig.clampedMinCropScale }
        let desired = min(1.0 / faceScale, processingConfig.clampedMaxCropScale)
        return max(processingConfig.clampedMinCropScale, desired)
    }

    private func makeFramingRect(
        centeredAt center: CGPoint,
        scale: Double
    ) -> CGRect {
        let zoom = max(1.0, scale)
        var width = 1.0 / zoom
        let ratioForFraming: CGFloat
        if aspectRatio == .auto {
            ratioForFraming = PiPAspectRatio.sixteenByNine.widthOverHeight
        } else {
            ratioForFraming = aspectRatio.widthOverHeight
        }
        var height = width / ratioForFraming

        if height > 1 {
            height = 1
            width = height * ratioForFraming
        }

        let rect = CGRect(
            x: center.x - width / 2.0,
            y: center.y - height / 2.0,
            width: width,
            height: height
        )
        return clampNormalized(rect)
    }

    private func renderPreviewImage(
        from pixelBuffer: CVPixelBuffer,
        framingRect: CGRect?
    ) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        if processingConfig.ciEnhancementEnabled {
            image = applyEnhancementFilters(to: image)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if let framingRect {
            let cropRect = VNImageRectForNormalizedRect(framingRect, width, height)
            let normalizedCrop = cropRect.standardized.intersection(image.extent)
            if normalizedCrop.width > 1, normalizedCrop.height > 1 {
                image = image.cropped(to: normalizedCrop)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    private func applyEnhancementFilters(to image: CIImage) -> CIImage {
        guard let colorFilter = CIFilter(name: "CIColorControls"),
              let sharpnessFilter = CIFilter(name: "CISharpenLuminance") else {
            return image
        }

        colorFilter.setValue(image, forKey: kCIInputImageKey)
        colorFilter.setValue(1.10, forKey: kCIInputSaturationKey)
        colorFilter.setValue(0.02, forKey: kCIInputBrightnessKey)
        colorFilter.setValue(1.06, forKey: kCIInputContrastKey)

        let colorAdjusted = colorFilter.outputImage ?? image
        sharpnessFilter.setValue(colorAdjusted, forKey: kCIInputImageKey)
        sharpnessFilter.setValue(0.35, forKey: kCIInputSharpnessKey)
        return sharpnessFilter.outputImage ?? colorAdjusted
    }

    private func clampNormalized(_ rect: CGRect) -> CGRect {
        var clamped = rect.standardized
        clamped.size.width = min(1, max(0.12, clamped.width))
        clamped.size.height = min(1, max(0.12, clamped.height))

        if clamped.minX < 0 {
            clamped.origin.x = 0
        }
        if clamped.minY < 0 {
            clamped.origin.y = 0
        }
        if clamped.maxX > 1 {
            clamped.origin.x = 1 - clamped.width
        }
        if clamped.maxY > 1 {
            clamped.origin.y = 1 - clamped.height
        }
        return clamped
    }

    private func interpolate(
        from: CGRect,
        to: CGRect,
        progress: Double
    ) -> CGRect {
        let p = min(1, max(0, progress))
        let x = from.origin.x + (to.origin.x - from.origin.x) * p
        let y = from.origin.y + (to.origin.y - from.origin.y) * p
        let w = from.size.width + (to.size.width - from.size.width) * p
        let h = from.size.height + (to.size.height - from.size.height) * p
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension PiPFrameProcessingEngine {
    struct FrameResult {
        let previewImage: CGImage
        let framingRect: CGRect?
        let keyframe: FaceFramingKeyframe?
    }
}
