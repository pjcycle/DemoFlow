//
//  VideoCuttingFFmpegModels.swift
//  DemoFlow
//
//  Created by Codex on 2026/5/12.
//

import CoreGraphics
import CoreMedia
import Foundation

struct VideoCuttingFFmpegProject {
    enum PerformanceProfile {
        case balanced
        case quality
    }

    let sourceURL: URL
    let keepRanges: [CMTimeRange]
    let cropRectNormalized: VideoCropRect
    let audioProcessingConfig: VideoCuttingAudioProcessingConfig
    let outputURL: URL
    let hasAudioTrack: Bool
    let performanceProfile: PerformanceProfile
}

struct FFmpegToolPaths {
    let ffmpegURL: URL
    let ffprobeURL: URL
}

struct FFmpegCommand {
    let executableURL: URL
    let arguments: [String]
    let expectedDurationSeconds: Double?
}

struct FFmpegExecutionResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}
