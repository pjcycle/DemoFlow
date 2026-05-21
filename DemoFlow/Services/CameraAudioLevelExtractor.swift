//
//  CameraAudioLevelExtractor.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/1.
//

import CoreMedia
import Foundation

enum CameraAudioLevelExtractor {
    nonisolated static func extract(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { return 0 }

        let bytesToRead = min(totalLength, 4096)
        var rawBytes = [UInt8](repeating: 0, count: bytesToRead)
        let status = CMBlockBufferCopyDataBytes(
            dataBuffer,
            atOffset: 0,
            dataLength: bytesToRead,
            destination: &rawBytes
        )
        guard status == kCMBlockBufferNoErr else { return 0 }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        let asbd = asbdPointer.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channels = max(Int(asbd.mChannelsPerFrame), 1)

        if isFloat && bitsPerChannel == 32 {
            return levelFromFloat32(rawBytes, channels: channels)
        }
        if bitsPerChannel == 32 {
            return levelFromInt32(rawBytes, channels: channels)
        }
        return levelFromInt16(rawBytes, channels: channels)
    }

    nonisolated private static func levelFromFloat32(_ bytes: [UInt8], channels: Int) -> Double {
        bytes.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Float.self)
            let count = pointer.count
            guard count > 0 else { return 0 }

            let step = max(channels, 1)
            var sum: Double = 0
            var sampleCount = 0
            var index = 0

            while index < count {
                let value = min(abs(Double(pointer[index])), 1)
                sum += value
                sampleCount += 1
                index += step
            }

            guard sampleCount > 0 else { return 0 }
            return min((sum / Double(sampleCount)) * 1.8, 1)
        }
    }

    nonisolated private static func levelFromInt32(_ bytes: [UInt8], channels: Int) -> Double {
        bytes.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int32.self)
            let count = pointer.count
            guard count > 0 else { return 0 }

            let step = max(channels, 1)
            var sum: Double = 0
            var sampleCount = 0
            var index = 0

            while index < count {
                let value = abs(Double(pointer[index])) / Double(Int32.max)
                sum += value
                sampleCount += 1
                index += step
            }

            guard sampleCount > 0 else { return 0 }
            return min((sum / Double(sampleCount)) * 2.2, 1)
        }
    }

    nonisolated private static func levelFromInt16(_ bytes: [UInt8], channels: Int) -> Double {
        bytes.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int16.self)
            let count = pointer.count
            guard count > 0 else { return 0 }

            let step = max(channels, 1)
            var sum: Double = 0
            var sampleCount = 0
            var index = 0

            while index < count {
                let value = abs(Double(pointer[index])) / Double(Int16.max)
                sum += value
                sampleCount += 1
                index += step
            }

            guard sampleCount > 0 else { return 0 }
            return min((sum / Double(sampleCount)) * 2.6, 1)
        }
    }
}
