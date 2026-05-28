//
//  PiPFramingKeyframeNormalizer.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import Foundation

enum PiPFramingKeyframeNormalizer {
    static func normalized(_ keyframes: [FaceFramingKeyframe]) -> [FaceFramingKeyframe] {
        let sorted = keyframes.sorted { $0.seconds < $1.seconds }
        var lastSeconds = -Double.greatestFiniteMagnitude
        return sorted.compactMap { frame in
            guard frame.seconds >= 0 else { return nil }
            guard frame.seconds >= lastSeconds else { return nil }
            lastSeconds = frame.seconds
            return FaceFramingKeyframe(
                id: frame.id,
                seconds: frame.seconds,
                normalizedRect: PiPGeometry.clampNormalized(frame.normalizedRect)
            )
        }
    }
}
