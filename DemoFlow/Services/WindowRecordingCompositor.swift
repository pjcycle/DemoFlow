//
//  WindowRecordingCompositor.swift
//  DemoFlow
//
//  2026-08-27 新增：窗口录制时把 PiP 摄像头帧叠加到屏幕抓帧右下角。
//  数据流：screen sampleBuffer + 最新 camera CGImage → 合成 CMSampleBuffer → 写盘。
//  只在 window 模式 + 启用 camera 时启用。
//

import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreImage
import Foundation

// @unchecked Sendable: 内部状态由 NSLock 保护，可从任何线程（含 SCStreamOutput 的 nonisolated 回调）安全访问。
final class WindowRecordingCompositor: @unchecked Sendable {
    nonisolated private let ciContext: CIContext
    nonisolated(unsafe) private let targetPixelBufferPool: CVPixelBufferPool?
    nonisolated private let cameraFrameLock = NSLock()
    nonisolated(unsafe) private var latestCameraFrame: CGImage?
    nonisolated private let pipFraction: CGFloat = 0.25
    nonisolated private let pipPadding: CGFloat = 12

    init?() {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ]
        ciContext = CIContext(options: options)
        targetPixelBufferPool = nil // 按需创建
    }

    nonisolated func updateLatestCameraFrame(_ cgImage: CGImage?) {
        cameraFrameLock.lock()
        latestCameraFrame = cgImage
        cameraFrameLock.unlock()
    }

    /// 返回可能已合成 PiP 的新 sampleBuffer；如果 PiP 未启用或 camera 帧未到则直接返回原 sampleBuffer
    nonisolated func process(sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard CMSampleBufferIsValid(sampleBuffer) else { return sampleBuffer }
        guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return sampleBuffer }

        cameraFrameLock.lock()
        let cameraFrame = latestCameraFrame
        cameraFrameLock.unlock()

        guard let cameraFrame else {
            return sampleBuffer
        }

        guard let compositedPixelBuffer = composite(
            screenPixelBuffer: screenPixelBuffer,
            cameraFrame: cameraFrame
        ) else {
            return sampleBuffer
        }

        return replaceImageBuffer(sampleBuffer: sampleBuffer, newImageBuffer: compositedPixelBuffer) ?? sampleBuffer
    }

    nonisolated private func composite(screenPixelBuffer: CVPixelBuffer, cameraFrame: CGImage) -> CVPixelBuffer? {
        let screenWidth = CVPixelBufferGetWidth(screenPixelBuffer)
        let screenHeight = CVPixelBufferGetHeight(screenPixelBuffer)
        guard screenWidth >= 64, screenHeight >= 64 else { return nil }

        let pipWidth = Int(CGFloat(screenWidth) * pipFraction)
        let pipHeight = Int(CGFloat(cameraFrame.height) * CGFloat(pipWidth) / CGFloat(max(1, cameraFrame.width)))
        let pipX = screenWidth - pipWidth - Int(pipPadding)
        let pipY = Int(pipPadding)

        // 在 screen 上画 camera
        // 用 vImage / CIBlendWithMask 或直接 CPU 绘制
        // 这里用直接 CVPixelBuffer 锁定 + CGContext.draw 简化实现
        return drawInto(
            screenPixelBuffer: screenPixelBuffer,
            cameraFrame: cameraFrame,
            pipRect: CGRect(x: pipX, y: pipY, width: pipWidth, height: pipHeight)
        )
    }

    nonisolated private func drawInto(
        screenPixelBuffer: CVPixelBuffer,
        cameraFrame: CGImage,
        pipRect: CGRect
    ) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(screenPixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(screenPixelBuffer, []) }

        let baseAddress = CVPixelBufferGetBaseAddress(screenPixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(screenPixelBuffer)
        let width = CVPixelBufferGetWidth(screenPixelBuffer)
        let height = CVPixelBufferGetHeight(screenPixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(screenPixelBuffer)

        guard pixelFormat == kCVPixelFormatType_32BGRA,
              let baseAddress,
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        // CGContext 坐标系是左上原点，Y 向下；pipRect 已经是左上坐标系，直接绘制即可
        context.saveGState()
        // 给 PiP 加一个圆角白底框
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let bgRect = pipRect.insetBy(dx: -2, dy: -2)
        let path = CGPath(roundedRect: bgRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()

        // 翻转 CGImage 然后画到 pipRect（CGImage 是 bottom-up origin）
        let drawRect = CGRect(x: pipRect.minX, y: pipRect.minY, width: pipRect.width, height: pipRect.height)
        context.saveGState()
        context.translateBy(x: 0, y: drawRect.maxY + drawRect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cameraFrame, in: CGRect(x: drawRect.minX, y: 0, width: drawRect.width, height: drawRect.height))
        context.restoreGState()
        context.restoreGState()

        return screenPixelBuffer
    }

    nonisolated private func replaceImageBuffer(sampleBuffer: CMSampleBuffer, newImageBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)
        var newSampleBuffer: CMSampleBuffer?
        let status = withUnsafePointer(to: &timingInfo) { timingPtr -> OSStatus in
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: newImageBuffer,
                formatDescription: formatDescription,
                sampleTiming: timingPtr,
                sampleBufferOut: &newSampleBuffer
            )
        }
        guard status == noErr, let newSampleBuffer else { return nil }
        return newSampleBuffer
    }
}