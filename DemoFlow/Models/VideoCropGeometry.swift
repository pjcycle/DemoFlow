//
//  VideoCropGeometry.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/5.
//

import CoreGraphics
import Foundation

enum VideoCropGeometry {
    private static let minNormalizedSize: CGFloat = 0.0001

    static func clampNormalizedRect(_ rect: CGRect) -> CGRect {
        var next = rect.standardized
        next.size.width = min(1, max(minNormalizedSize, next.width))
        next.size.height = min(1, max(minNormalizedSize, next.height))
        if next.minX < 0 {
            next.origin.x = 0
        }
        if next.minY < 0 {
            next.origin.y = 0
        }
        if next.maxX > 1 {
            next.origin.x = 1 - next.width
        }
        if next.maxY > 1 {
            next.origin.y = 1 - next.height
        }
        return next
    }

    static func normalizeMinSize(
        minPoints: CGSize,
        videoDisplaySize: CGSize
    ) -> CGSize {
        guard videoDisplaySize.width > 1, videoDisplaySize.height > 1 else {
            return CGSize(width: 0.1, height: 0.1)
        }
        return CGSize(
            width: min(1, max(minNormalizedSize, minPoints.width / videoDisplaySize.width)),
            height: min(1, max(minNormalizedSize, minPoints.height / videoDisplaySize.height))
        )
    }

    static func aspectFitRect(
        contentSize: CGSize,
        boundingSize: CGSize
    ) -> CGRect {
        guard contentSize.width > 0,
              contentSize.height > 0,
              boundingSize.width > 0,
              boundingSize.height > 0 else {
            return CGRect(origin: .zero, size: boundingSize)
        }

        let scale = min(boundingSize.width / contentSize.width, boundingSize.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let x = (boundingSize.width - size.width) / 2.0
        let y = (boundingSize.height - size.height) / 2.0
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func enforceMinSize(
        _ rect: CGRect,
        minSize: CGSize
    ) -> CGRect {
        var next = rect.standardized
        next.size.width = max(next.width, minSize.width)
        next.size.height = max(next.height, minSize.height)
        return clampNormalizedRect(next)
    }

    static func adjustedRectForAspect(
        rect: CGRect,
        targetRatio: CGFloat?,
        minSize: CGSize
    ) -> CGRect {
        guard let targetRatio, targetRatio > 0 else {
            return enforceMinSize(rect, minSize: minSize)
        }

        var next = rect.standardized
        let center = CGPoint(x: next.midX, y: next.midY)

        var width = max(next.width, minSize.width)
        var height = width / targetRatio
        if height < minSize.height {
            height = minSize.height
            width = height * targetRatio
        }

        if width > 1 {
            width = 1
            height = width / targetRatio
        }
        if height > 1 {
            height = 1
            width = height * targetRatio
        }

        next = CGRect(
            x: center.x - width / 2.0,
            y: center.y - height / 2.0,
            width: width,
            height: height
        )

        return clampNormalizedRect(next)
    }

    static func applyDrag(
        startRect: CGRect,
        translation: CGSize,
        handle: VideoCropHandle,
        displaySize: CGSize,
        lockedAspectRatio: CGFloat?,
        minSize: CGSize
    ) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return startRect }
        let dx = translation.width / displaySize.width
        let dy = translation.height / displaySize.height
        let normalizedStart = clampNormalizedRect(startRect.standardized)
        let normalizedMinSize = CGSize(
            width: min(1, max(minNormalizedSize, minSize.width)),
            height: min(1, max(minNormalizedSize, minSize.height))
        )

        // Dragging inside crop frame should only move position and keep size.
        if handle == .move {
            let moved = normalizedStart.offsetBy(dx: dx, dy: dy)
            return clampPositionOnly(moved)
        }

        // Adaptive mode: free-resize with min-size and bounds clamp.
        guard let lockedAspectRatio, lockedAspectRatio > 0 else {
            var rect = applyHandleResize(
                rect: normalizedStart,
                dx: dx,
                dy: dy,
                handle: handle
            )
            rect = enforceMinSize(rect, minSize: normalizedMinSize)
            return clampNormalizedRect(rect)
        }

        // Fixed-ratio mode: any edge/corner scales around center.
        let centerScaled = scaleFromCenter(
            startRect: normalizedStart,
            dx: dx,
            dy: dy,
            handle: handle,
            aspectRatio: lockedAspectRatio,
            minSize: normalizedMinSize
        )
        let clamped = clampPositionOnly(centerScaled)
        let corrected = fitRectKeepingCenter(
            rect: clamped,
            center: CGPoint(x: clamped.midX, y: clamped.midY),
            aspectRatio: lockedAspectRatio,
            minSize: normalizedMinSize
        )
        return clampPositionOnly(corrected)
    }

    static func fitRectKeepingCenter(
        rect: CGRect,
        center: CGPoint,
        aspectRatio: CGFloat,
        minSize: CGSize
    ) -> CGRect {
        var width = max(rect.width, minSize.width)
        var height = width / aspectRatio
        if height < minSize.height {
            height = minSize.height
            width = height * aspectRatio
        }

        if width > 1 {
            width = 1
            height = width / aspectRatio
        }
        if height > 1 {
            height = 1
            width = height * aspectRatio
        }

        let next = CGRect(
            x: center.x - width / 2.0,
            y: center.y - height / 2.0,
            width: width,
            height: height
        )
        return clampNormalizedRect(next)
    }

    private static func applyHandleResize(
        rect: CGRect,
        dx: CGFloat,
        dy: CGFloat,
        handle: VideoCropHandle
    ) -> CGRect {
        var next = rect.standardized
        switch handle {
        case .move:
            next.origin.x += dx
            next.origin.y += dy
        case .left:
            next.origin.x += dx
            next.size.width -= dx
        case .right:
            next.size.width += dx
        case .top:
            next.origin.y += dy
            next.size.height -= dy
        case .bottom:
            next.size.height += dy
        case .topLeft:
            next.origin.x += dx
            next.size.width -= dx
            next.origin.y += dy
            next.size.height -= dy
        case .topRight:
            next.size.width += dx
            next.origin.y += dy
            next.size.height -= dy
        case .bottomLeft:
            next.origin.x += dx
            next.size.width -= dx
            next.size.height += dy
        case .bottomRight:
            next.size.width += dx
            next.size.height += dy
        }
        return next.standardized
    }

    private static func scaleFromCenter(
        startRect: CGRect,
        dx: CGFloat,
        dy: CGFloat,
        handle: VideoCropHandle,
        aspectRatio: CGFloat,
        minSize: CGSize
    ) -> CGRect {
        let base = fitRectKeepingCenter(
            rect: startRect,
            center: CGPoint(x: startRect.midX, y: startRect.midY),
            aspectRatio: aspectRatio,
            minSize: minSize
        )
        let center = CGPoint(x: base.midX, y: base.midY)
        let width = max(base.width, minNormalizedSize)
        let height = max(base.height, minNormalizedSize)

        let scaleDelta: CGFloat
        switch handle {
        case .left:
            scaleDelta = -dx / width
        case .right:
            scaleDelta = dx / width
        case .top:
            scaleDelta = -dy / height
        case .bottom:
            scaleDelta = dy / height
        case .topLeft:
            scaleDelta = max(-dx / width, -dy / height)
        case .topRight:
            scaleDelta = max(dx / width, -dy / height)
        case .bottomLeft:
            scaleDelta = max(-dx / width, dy / height)
        case .bottomRight:
            scaleDelta = max(dx / width, dy / height)
        case .move:
            scaleDelta = 0
        }

        let minWidthForAspect = max(minSize.width, minSize.height * aspectRatio)
        let minHeightForAspect = max(minSize.height, minSize.width / aspectRatio)
        let minScale = max(minWidthForAspect / width, minHeightForAspect / height)
        let targetScale = max(minScale, 1 + scaleDelta)

        let scaledWidth = min(1, max(minWidthForAspect, width * targetScale))
        let scaledHeight = min(1, max(minHeightForAspect, scaledWidth / aspectRatio))

        return CGRect(
            x: center.x - scaledWidth / 2.0,
            y: center.y - scaledHeight / 2.0,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    private static func clampPositionOnly(_ rect: CGRect) -> CGRect {
        var next = rect.standardized
        next.size.width = min(1, max(minNormalizedSize, next.width))
        next.size.height = min(1, max(minNormalizedSize, next.height))
        next.origin.x = min(max(0, next.origin.x), 1 - next.width)
        next.origin.y = min(max(0, next.origin.y), 1 - next.height)
        return next
    }

}
