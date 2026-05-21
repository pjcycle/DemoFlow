//
//  ScreenDrawSessionStore.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/7.
//

import AppKit
import Combine
import QuartzCore
import Foundation

@MainActor
final class ScreenDrawSessionStore: ObservableObject {
    @Published var activeTool: ScreenDrawTool = .line
    @Published var selectedColorPreset: DrawColorPreset = .one
    @Published var handDrawnIntensity: CGFloat = 0.58
    @Published var markStyle: ScreenDrawMarkStyle = .rounded
    @Published var dismissalAnimationMode: DrawDismissalAnimationMode = .random
    @Published var dismissalAnimationFixedStyle: DrawDismissalAnimationStyle = .shatterDrop
    @Published private(set) var isDismissingWithAnimation = false
    @Published private(set) var activeDismissalStyle: DrawDismissalAnimationStyle?
    @Published private(set) var dismissalAnimationStartedAt: CFTimeInterval = 0
    @Published private(set) var shapes: [ScreenDrawShape] = []
    @Published private(set) var previewShape: ScreenDrawShape?

    var onSessionEvent: ((String) -> Void)?

    private let defaultLineWidth: CGFloat = 2
    private let moveHitTolerance: CGFloat = 12
    private var lastDismissalStyle: DrawDismissalAnimationStyle?
    private var shapeDragState: ShapeDragState?

    func beginInteraction(at point: CGPoint) {
        guard !isDismissingWithAnimation else { return }
        shapeDragState = nil
        guard let shapeType = shapeType(for: activeTool) else { return }
        previewShape = ScreenDrawShape(
            type: shapeType,
            startPoint: point,
            endPoint: point,
            points: [point],
            colorPreset: selectedColorPreset,
            lineWidth: defaultLineWidth
        )
    }

    func continueInteraction(at point: CGPoint) {
        guard !isDismissingWithAnimation else { return }
        guard var shape = previewShape else {
            beginInteraction(at: point)
            return
        }
        shape.endPoint = point
        if shape.type == .line || shape.type == .arrow {
            appendSamplePoint(point, to: &shape.points)
        }
        previewShape = shape
    }

    func endInteraction(at point: CGPoint) {
        guard !isDismissingWithAnimation else { return }
        guard var shape = previewShape else { return }
        shape.endPoint = point
        if shape.type == .line || shape.type == .arrow {
            appendSamplePoint(point, to: &shape.points)
            if shape.points.count == 1 {
                shape.points.append(shape.points[0])
            }
        }
        if shouldCommitShape(shape) {
            shapes.append(shape)
            onSessionEvent?(
                L10n.f(
                    "fmt.draw.shape_added",
                    shape.type.tool.title,
                    shape.colorPreset.shortLabel
                )
            )
        }
        previewShape = nil
    }

    func clearCanvas() {
        guard !isDismissingWithAnimation else { return }
        if shapes.isEmpty {
            onSessionEvent?(L10n.tr("legacy.key_182"))
            return
        }
        shapeDragState = nil
        shapes.removeAll(keepingCapacity: false)
        previewShape = nil
        onSessionEvent?(L10n.tr("legacy.key_181"))
    }

    func clearCanvasSilently() {
        shapeDragState = nil
        shapes.removeAll(keepingCapacity: false)
        previewShape = nil
    }

    func resetForNewSession() {
        shapeDragState = nil
        shapes.removeAll(keepingCapacity: false)
        previewShape = nil
        isDismissingWithAnimation = false
        activeDismissalStyle = nil
        dismissalAnimationStartedAt = 0
    }

    func cancelCurrentInteraction() {
        previewShape = nil
    }

    @discardableResult
    func beginShapeDragIfNeeded(at point: CGPoint) -> Bool {
        guard !isDismissingWithAnimation else { return false }
        guard previewShape == nil else { return false }
        guard let shapeID = hitTestShapeID(at: point) else { return false }

        bringShapeToFront(id: shapeID)
        shapeDragState = ShapeDragState(shapeID: shapeID, lastPoint: point)
        return true
    }

    func continueShapeDrag(to point: CGPoint) {
        guard var dragState = shapeDragState else { return }
        let delta = CGPoint(
            x: point.x - dragState.lastPoint.x,
            y: point.y - dragState.lastPoint.y
        )
        guard abs(delta.x) > 0.01 || abs(delta.y) > 0.01 else { return }
        moveShape(id: dragState.shapeID, by: delta)
        dragState.lastPoint = point
        dragState.hasMoved = true
        shapeDragState = dragState
    }

    func endShapeDrag(at point: CGPoint) {
        guard shapeDragState != nil else { return }
        continueShapeDrag(to: point)
        let hasMoved = shapeDragState?.hasMoved == true
        shapeDragState = nil
        if hasMoved {
            onSessionEvent?(L10n.tr("draw.move.finished"))
        }
    }

    func cancelActivePointerInteraction() {
        previewShape = nil
        let hasMoved = shapeDragState?.hasMoved == true
        shapeDragState = nil
        if hasMoved {
            onSessionEvent?(L10n.tr("draw.move.finished"))
        }
    }

    func undoLastShape() {
        guard !isDismissingWithAnimation else { return }

        shapeDragState = nil
        if previewShape != nil {
            previewShape = nil
            onSessionEvent?(L10n.tr("draw.undo.preview_canceled"))
            return
        }

        guard !shapes.isEmpty else {
            onSessionEvent?(L10n.tr("draw.undo.empty"))
            return
        }

        _ = shapes.removeLast()
        onSessionEvent?(L10n.tr("draw.undo.shape_removed"))
    }

    var hasDrawableContent: Bool {
        !shapes.isEmpty || previewShape != nil
    }

    var isDraggingExistingShape: Bool {
        shapeDragState != nil
    }

    func beginDismissalAnimation() -> DrawDismissalAnimationStyle? {
        guard hasDrawableContent else { return nil }
        guard !isDismissingWithAnimation else { return activeDismissalStyle }

        let style = resolvedDismissalStyle()
        isDismissingWithAnimation = true
        activeDismissalStyle = style
        dismissalAnimationStartedAt = CACurrentMediaTime()
        shapeDragState = nil
        previewShape = nil
        return style
    }

    func completeDismissalAnimation(clearCanvas: Bool) {
        if clearCanvas {
            clearCanvasSilently()
            onSessionEvent?(L10n.tr("legacy.key_181"))
        }
        isDismissingWithAnimation = false
        activeDismissalStyle = nil
        dismissalAnimationStartedAt = 0
    }

    private func shapeType(for tool: ScreenDrawTool) -> ScreenDrawShapeType? {
        switch tool {
        case .line:
            return .line
        case .arrow:
            return .arrow
        case .rectangle:
            return .rectangle
        case .ellipse:
            return .ellipse
        case .cross:
            return .cross
        case .check:
            return .check
        }
    }

    private func shouldCommitShape(_ shape: ScreenDrawShape) -> Bool {
        if shape.type == .line || shape.type == .arrow {
            let sampled = shape.points
            if sampled.count >= 2 {
                return sampledTotalLength(sampled) >= 2.5
            }
        }
        let dx = shape.endPoint.x - shape.startPoint.x
        let dy = shape.endPoint.y - shape.startPoint.y
        return hypot(dx, dy) >= 2.5
    }

    private func appendSamplePoint(_ point: CGPoint, to points: inout [CGPoint]) {
        if let last = points.last {
            let distance = hypot(point.x - last.x, point.y - last.y)
            if distance < 0.75 {
                return
            }
        }
        points.append(point)
    }

    private func sampledTotalLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for index in 1 ..< points.count {
            let previous = points[index - 1]
            let current = points[index]
            total += hypot(current.x - previous.x, current.y - previous.y)
        }
        return total
    }

    private func hitTestShapeID(at point: CGPoint) -> UUID? {
        for shape in shapes.reversed() {
            if hitTest(shape, at: point) {
                return shape.id
            }
        }
        return nil
    }

    private func hitTest(_ shape: ScreenDrawShape, at point: CGPoint) -> Bool {
        let tolerance = max(moveHitTolerance, shape.lineWidth * 3)
        switch shape.type {
        case .line, .arrow:
            let trail = resolvedTrailPoints(for: shape)
            if trailContains(point, points: trail, tolerance: tolerance) {
                return true
            }
            return expandedBounds(for: shape, tolerance: tolerance).contains(point)
        case .rectangle, .ellipse, .cross, .check:
            return expandedBounds(for: shape, tolerance: tolerance).contains(point)
        }
    }

    private func resolvedTrailPoints(for shape: ScreenDrawShape) -> [CGPoint] {
        if shape.points.count >= 2 {
            return shape.points
        }
        if shape.points.count == 1 {
            return [shape.points[0], shape.endPoint]
        }
        return [shape.startPoint, shape.endPoint]
    }

    private func trailContains(_ point: CGPoint, points: [CGPoint], tolerance: CGFloat) -> Bool {
        guard !points.isEmpty else { return false }
        if points.count == 1 {
            return hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance
        }

        for index in 1 ..< points.count {
            if distanceFromPoint(point, toSegmentStart: points[index - 1], end: points[index]) <= tolerance {
                return true
            }
        }
        return false
    }

    private func distanceFromPoint(_ point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(
            0,
            min(
                1,
                ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
            )
        )
        let projected = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    private func expandedBounds(for shape: ScreenDrawShape, tolerance: CGFloat) -> CGRect {
        shapeBounds(shape).insetBy(dx: -tolerance, dy: -tolerance)
    }

    private func shapeBounds(_ shape: ScreenDrawShape) -> CGRect {
        switch shape.type {
        case .line, .arrow:
            let trail = resolvedTrailPoints(for: shape)
            let xs = trail.map(\.x)
            let ys = trail.map(\.y)
            let minX = xs.min() ?? shape.startPoint.x
            let maxX = xs.max() ?? shape.endPoint.x
            let minY = ys.min() ?? shape.startPoint.y
            let maxY = ys.max() ?? shape.endPoint.y
            return CGRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX),
                height: max(1, maxY - minY)
            )
        case .rectangle, .ellipse, .cross, .check:
            return CGRect(
                x: min(shape.startPoint.x, shape.endPoint.x),
                y: min(shape.startPoint.y, shape.endPoint.y),
                width: abs(shape.endPoint.x - shape.startPoint.x),
                height: abs(shape.endPoint.y - shape.startPoint.y)
            )
        }
    }

    private func bringShapeToFront(id: UUID) {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
        guard index != shapes.count - 1 else { return }
        let shape = shapes.remove(at: index)
        shapes.append(shape)
    }

    private func moveShape(id: UUID, by delta: CGPoint) {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
        var shape = shapes[index]
        shape.translate(by: delta)
        shapes[index] = shape
    }

    private func resolvedDismissalStyle() -> DrawDismissalAnimationStyle {
        switch dismissalAnimationMode {
        case .fixed:
            lastDismissalStyle = dismissalAnimationFixedStyle
            return dismissalAnimationFixedStyle
        case .random:
            let all = DrawDismissalAnimationStyle.allCases
            if all.count <= 1 {
                let fallback = dismissalAnimationFixedStyle
                lastDismissalStyle = fallback
                return fallback
            }

            var candidate = all.randomElement() ?? dismissalAnimationFixedStyle
            if candidate == lastDismissalStyle, let different = all.first(where: { $0 != candidate }) {
                candidate = different
            }
            lastDismissalStyle = candidate
            return candidate
        }
    }
}

private struct ShapeDragState {
    let shapeID: UUID
    var lastPoint: CGPoint
    var hasMoved = false
}
