//
//  PiPGeometry.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import CoreGraphics
import Foundation

enum PiPGeometry {
    static let maxWidthRatio: CGFloat = 0.7

    static func normalizeLayout(
        _ layout: PiPLayoutState,
        screenSize: CGSize
    ) -> PiPLayoutState {
        guard screenSize.width > 1, screenSize.height > 1 else { return layout }

        if layout.aspectRatio == .auto {
            let autoRect = autoScaledRect(
                normalizedRect: layout.normalizedRect,
                screenSize: screenSize
            )
            return PiPLayoutState(normalizedRect: autoRect, aspectRatio: .auto)
        }

        var rect = layout.normalizedRect.standardized
        let minimumNormalizedWidth = PiPLayoutState.minimumSize.width / screenSize.width
        let minimumNormalizedHeight = PiPLayoutState.minimumSize.height / screenSize.height
        let aspectRatio = max(layout.aspectRatio.widthOverHeight, 0.01)

        var normalizedHeight = max(minimumNormalizedHeight, rect.height)
        var normalizedWidth = max(minimumNormalizedWidth, normalizedHeight * aspectRatio)

        if normalizedWidth > maxWidthRatio {
            normalizedWidth = maxWidthRatio
            normalizedHeight = max(minimumNormalizedHeight, normalizedWidth / aspectRatio)
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        rect.size = CGSize(width: normalizedWidth, height: normalizedHeight)
        rect.origin.x = center.x - normalizedWidth / 2.0
        rect.origin.y = center.y - normalizedHeight / 2.0
        rect = clampNormalized(rect)

        return PiPLayoutState(normalizedRect: rect, aspectRatio: layout.aspectRatio)
    }

    static func applyAspectSwitchKeepHeight(
        normalizedRect: CGRect,
        targetAspectRatio: PiPAspectRatio,
        screenSize: CGSize
    ) -> CGRect {
        if targetAspectRatio == .auto {
            return autoScaledRect(
                normalizedRect: normalizedRect,
                screenSize: screenSize
            )
        }
        guard screenSize.width > 1, screenSize.height > 1 else {
            return normalizedRect.standardized
        }

        let rect = normalizedRect.standardized
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let targetHeightPixels = max(
            PiPLayoutState.minimumSize.height,
            rect.height * screenSize.height
        )
        var targetWidthPixels = max(
            PiPLayoutState.minimumSize.width,
            targetAspectRatio.width(forHeight: targetHeightPixels)
        )
        targetWidthPixels = min(targetWidthPixels, screenSize.width * maxWidthRatio)
        let clampedHeightPixels = max(
            PiPLayoutState.minimumSize.height,
            targetAspectRatio.height(forWidth: targetWidthPixels)
        )

        var next = CGRect(
            x: center.x - (targetWidthPixels / screenSize.width) / 2.0,
            y: center.y - (clampedHeightPixels / screenSize.height) / 2.0,
            width: targetWidthPixels / screenSize.width,
            height: clampedHeightPixels / screenSize.height
        )
        next = clampNormalized(next)
        return next
    }

    static func autoScaledRect(
        normalizedRect: CGRect,
        screenSize: CGSize
    ) -> CGRect {
        guard screenSize.width > 1, screenSize.height > 1 else {
            return normalizedRect.standardized
        }

        let rect = normalizedRect.standardized
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minWidth = PiPLayoutState.minimumSize.width / screenSize.width
        let minHeight = PiPLayoutState.minimumSize.height / screenSize.height

        var width = max(minWidth, min(rect.width, maxWidthRatio))
        var height = max(minHeight, rect.height)

        if width > maxWidthRatio {
            width = maxWidthRatio
        }
        if center.x + width / 2.0 > 1 {
            width = min(width, max(minWidth, (1.0 - center.x) * 2.0))
        }
        if center.x - width / 2.0 < 0 {
            width = min(width, max(minWidth, center.x * 2.0))
        }
        if center.y + height / 2.0 > 1 {
            height = min(height, max(minHeight, (1.0 - center.y) * 2.0))
        }
        if center.y - height / 2.0 < 0 {
            height = min(height, max(minHeight, center.y * 2.0))
        }

        var next = CGRect(
            x: center.x - width / 2.0,
            y: center.y - height / 2.0,
            width: width,
            height: height
        )
        next = clampNormalized(next)
        return next
    }

    static func clampNormalized(_ rect: CGRect) -> CGRect {
        var clamped = rect.standardized
        clamped.size.width = min(1, max(0.0001, clamped.width))
        clamped.size.height = min(1, max(0.0001, clamped.height))
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
}
