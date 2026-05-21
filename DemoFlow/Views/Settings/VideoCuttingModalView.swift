//
//  VideoCuttingModalView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct VideoCuttingModalView: View {
    private enum CropInteractionABMode {
        case normal
        case resizeOnly
        case moveOnly
    }

    @ObservedObject var viewModel: VideoCuttingViewModel
    @ObservedObject var appCoordinator: AppCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    let windowID: String?

    @State private var cropDragStartRect: CGRect?
    @State private var hoveredCropHandle: VideoCropHandle?
    @State private var activeDragHandle: VideoCropHandle?
    @State private var isDeleteTrackHovered = false
    @State private var pendingDeleteStartText = ""
    @State private var pendingDeleteEndText = ""
    private let cropResizeHotspotDiameter: CGFloat = 50
    private let cropInteractionCoordinateSpace = "videoCuttingCropInteractionSpace"
    private let cropInteractionABMode: CropInteractionABMode = .normal

    private let aspectGridRows: [[VideoCuttingAspectPreset]] = [
        [.adaptive, .nineBySixteen, .sixteenByNine, .oneByOne],
        [.fourByThree, .threeByFour, .fivePointEight, .twoByOne],
        [.twoPointThreeFiveByOne, .onePointEightFiveByOne]
    ]
    private let dropTypeIdentifiers = VideoCuttingImportService().dropTypeIdentifiers

    init(
        viewModel: VideoCuttingViewModel,
        appCoordinator: AppCoordinator,
        windowID: String? = nil
    ) {
        self.viewModel = viewModel
        self.appCoordinator = appCoordinator
        self.windowID = windowID
    }

    var body: some View {
        VStack(spacing: 0) {
            bodyContent
            Divider().overlay(Color.black.opacity(0.35))
            bottomBar
        }
        .frame(minWidth: 1320, minHeight: 860)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .onDrop(of: dropTypeIdentifiers, isTargeted: nil) { providers in
            viewModel.handleDrop(providers: providers)
            return true
        }
        .onDisappear {
            viewModel.pausePlayback()
        }
        .onChange(of: appCoordinator.resolvedLanguage) { _, _ in
            // Force window title to follow current language immediately.
            updateWindowTitle()
        }
        .onAppear {
            updateWindowTitle()
        }
    }

    private var bodyContent: some View {
        HStack(spacing: 0) {
            previewPanel
            Divider().overlay(Color.black.opacity(0.35))
            sidePanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black

                if viewModel.hasSource {
                    videoPreview
                } else {
                    importDropZone
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.hasSource {
                timelineBar
            }
        }
    }

    private var importDropZone: some View {
        Button {
            viewModel.importByPanel()
        } label: {
            VStack(spacing: 16) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Color.cyan.opacity(0.95))
                Text(L10n.tr("legacy.key_54"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(L10n.tr("legacy.key_133"))
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(L10n.tr("legacy.key_213"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.cyan.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 680, height: 430)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .foregroundStyle(Color.white.opacity(0.2))
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var videoPreview: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let fitRect = VideoCropGeometry.aspectFitRect(
                contentSize: viewModel.sourceVideoSize,
                boundingSize: proxy.size
            )
            ZStack {
                MacVideoPlayerView(player: viewModel.player)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)

                cropOverlay(fitRect: fitRect)
            }
            .coordinateSpace(name: cropInteractionCoordinateSpace)
            .contentShape(Rectangle())
            .frame(width: bounds.width, height: bounds.height)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func cropOverlay(fitRect: CGRect) -> some View {
        let crop = VideoCropGeometry.clampNormalizedRect(viewModel.cropRectNormalized.cgRect)
        let cropFrame = CGRect(
            x: fitRect.minX + fitRect.width * crop.minX,
            y: fitRect.minY + fitRect.height * crop.minY,
            width: fitRect.width * crop.width,
            height: fitRect.height * crop.height
        )

        return ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .mask(
                    Rectangle().overlay(
                        Rectangle()
                            .frame(width: cropFrame.width, height: cropFrame.height)
                            .offset(x: cropFrame.midX - fitRect.midX, y: cropFrame.midY - fitRect.midY)
                            .blendMode(.destinationOut)
                    )
                )
                .compositingGroup()
                .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.cyan.opacity(0.95), lineWidth: 2)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .offset(
                    x: cropFrame.midX - fitRect.midX,
                    y: cropFrame.midY - fitRect.midY
                )
                .allowsHitTesting(false)
                .zIndex(1)

            // Single interaction layer: determines move/resize by drag start position.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: cropFrame.width, height: cropFrame.height)
                .offset(
                    x: cropFrame.midX - fitRect.midX,
                    y: cropFrame.midY - fitRect.midY
                )
                .contentShape(Rectangle())
                .gesture(cropInteractionGesture(fitRect: fitRect, cropFrame: cropFrame))
                .onContinuousHover(coordinateSpace: .named(cropInteractionCoordinateSpace)) { phase in
                    switch phase {
                    case .active(let location):
                        guard cropDragStartRect == nil else { return }
                        let detected = cropHandle(at: location, cropFrame: cropFrame) ?? .move
                        if let resolved = resolveHandleForAB(detected) {
                            hoveredCropHandle = resolved
                            hoverCursor(for: resolved).set()
                        } else {
                            hoveredCropHandle = nil
                            NSCursor.arrow.set()
                        }
                    case .ended:
                        hoveredCropHandle = nil
                        guard cropDragStartRect == nil else { return }
                        NSCursor.arrow.set()
                    }
                }
                .zIndex(2)

            cropHandles(cropFrame: cropFrame, fitRect: fitRect)
                .zIndex(3)
        }
    }

    private func cropHandles(cropFrame: CGRect, fitRect: CGRect) -> some View {
        return ZStack {
            handleDot(position: CGPoint(x: cropFrame.minX, y: cropFrame.minY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.midX, y: cropFrame.minY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.maxX, y: cropFrame.minY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.minX, y: cropFrame.midY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.maxX, y: cropFrame.midY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.minX, y: cropFrame.maxY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.midX, y: cropFrame.maxY), fitRect: fitRect)
            handleDot(position: CGPoint(x: cropFrame.maxX, y: cropFrame.maxY), fitRect: fitRect)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func handleDot(
        position: CGPoint,
        fitRect: CGRect
    ) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 10, height: 10)
            .offset(
                x: position.x - fitRect.midX,
                y: position.y - fitRect.midY
            )
            .allowsHitTesting(false)
    }

    private func cropInteractionGesture(
        fitRect: CGRect,
        cropFrame: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(cropInteractionCoordinateSpace))
            .onChanged { value in
                if activeDragHandle == nil {
                    let detected = cropHandle(at: value.startLocation, cropFrame: cropFrame) ?? .move
                    activeDragHandle = resolveHandleForAB(detected)
                }
                guard let handle = activeDragHandle else { return }
                if hoveredCropHandle == nil {
                    hoveredCropHandle = handle
                }
                setDragCursor(for: handle)
                if cropDragStartRect == nil {
                    cropDragStartRect = viewModel.cropRectNormalized.cgRect
                }
                guard let start = cropDragStartRect else { return }

                if viewModel.cropRectNormalized.cgRect != start {
                    // keep using the first rect for stable relative drag
                }

                viewModel.cropRectNormalized = VideoCropRect(start)
                viewModel.updateCropRectByDrag(
                    handle: handle,
                    translation: value.translation,
                    overlayVideoDisplaySize: fitRect.size
                )
            }
            .onEnded { _ in
                cropDragStartRect = nil
                if let handle = activeDragHandle {
                    activeDragHandle = nil
                    hoveredCropHandle = handle
                    hoverCursor(for: handle).set()
                } else {
                    hoveredCropHandle = nil
                    NSCursor.arrow.set()
                }
            }
    }

    private func setDragCursor(for handle: VideoCropHandle) {
        if handle == .move {
            NSCursor.closedHand.set()
        } else {
            hoverCursor(for: handle).set()
        }
    }

    private func hoverCursor(for handle: VideoCropHandle) -> NSCursor {
        switch handle {
        case .move:
            return .openHand
        case .left, .right:
            return frameResizeCursor(for: handle)
        case .top, .bottom:
            return frameResizeCursor(for: handle)
        case .topLeft, .bottomRight:
            return frameResizeCursor(for: handle)
        case .topRight, .bottomLeft:
            return frameResizeCursor(for: handle)
        }
    }

    private func cropHandle(at location: CGPoint, cropFrame: CGRect) -> VideoCropHandle? {
        guard cropFrame.width > 0, cropFrame.height > 0 else { return nil }
        let radius = cropResizeHotspotDiameter / 2.0
        let points: [(VideoCropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: cropFrame.minX, y: cropFrame.minY)),
            (.top, CGPoint(x: cropFrame.midX, y: cropFrame.minY)),
            (.topRight, CGPoint(x: cropFrame.maxX, y: cropFrame.minY)),
            (.left, CGPoint(x: cropFrame.minX, y: cropFrame.midY)),
            (.right, CGPoint(x: cropFrame.maxX, y: cropFrame.midY)),
            (.bottomLeft, CGPoint(x: cropFrame.minX, y: cropFrame.maxY)),
            (.bottom, CGPoint(x: cropFrame.midX, y: cropFrame.maxY)),
            (.bottomRight, CGPoint(x: cropFrame.maxX, y: cropFrame.maxY))
        ]

        var bestHandle: VideoCropHandle?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (handle, point) in points {
            let dx = location.x - point.x
            let dy = location.y - point.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance <= radius, distance < bestDistance {
                bestDistance = distance
                bestHandle = handle
            }
        }
        return bestHandle
    }

    private func resolveHandleForAB(_ detected: VideoCropHandle) -> VideoCropHandle? {
        switch cropInteractionABMode {
        case .normal:
            return detected
        case .resizeOnly:
            return detected == .move ? nil : detected
        case .moveOnly:
            return .move
        }
    }

    private func frameResizeCursor(for handle: VideoCropHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .left:
                position = .left
            case .right:
                position = .right
            case .top:
                position = .top
            case .bottom:
                position = .bottom
            case .topLeft:
                position = .topLeft
            case .topRight:
                position = .topRight
            case .bottomLeft:
                position = .bottomLeft
            case .bottomRight:
                position = .bottomRight
            case .move:
                return .openHand
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }

        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .resizeUpDown
        case .move:
            return .openHand
        }
    }

    private var timelineBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Color.white.opacity(0.95))
                }
                .buttonStyle(.plain)

                Text(viewModel.currentTimeText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.92))

                Text(L10n.tr("legacy.key_12"))
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
                TextField("0", text: $viewModel.keepStartText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)

                Text(L10n.tr("legacy.key_13"))
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
                TextField("10", text: $viewModel.keepEndText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)

                Button(L10n.tr("legacy.key_96")) {
                    viewModel.applyQuickKeepRangeInput()
                }
                .buttonStyle(.bordered)

                Text(viewModel.totalDurationText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))

                Spacer(minLength: 0)
            }

            Slider(
                value: Binding(
                    get: { viewModel.playbackPosition },
                    set: { viewModel.scrub(to: $0) }
                ),
                in: 0...max(viewModel.sourceDuration, 0.1)
            )
            .tint(Color.cyan.opacity(0.95))

            deleteTrackToolbar
            deleteTrackArea
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.62))
    }

    private var deleteTrackToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L10n.tr("legacy.key_24"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.8))

                Text("FPS \(String(format: "%.2f", viewModel.videoFPS))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.52))

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text(L10n.tr("video.delete.hover_add_hint"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.72))

                Button(viewModel.isExporting ? L10n.tr("legacy.key_46") : L10n.tr("legacy.key_211")) {
                    viewModel.deleteSelectedRangeAndReload()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canDeleteSelectedRangeAndReload)

                Button(viewModel.isExporting ? L10n.tr("legacy.key_46") : L10n.tr("video.delete.apply_all")) {
                    viewModel.applyAllDeleteRangesAndReload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canApplyAllDeleteRangesAndReload)

                Spacer(minLength: 0)
            }
        }
    }

    private var deleteTrackArea: some View {
        GeometryReader { proxy in
            VStack(spacing: 6) {
                if shouldShowDeleteInputBubble {
                    deleteInputBubble
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !viewModel.deleteRanges.isEmpty {
                    deleteRangeBubblesRow
                }

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)

                    if viewModel.deleteRanges.isEmpty {
                        Text(L10n.tr("legacy.key_158"))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.45))
                            .padding(.horizontal, 10)
                    } else {
                        ForEach(viewModel.deleteRanges) { range in
                            deleteRangeChip(range: range, trackWidth: proxy.size.width)
                        }
                    }
                }
                .frame(height: 42)
            }
            .contentShape(Rectangle())
            .onAppear {
                syncPendingDeleteInput()
            }
            .onHover { isHovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isDeleteTrackHovered = isHovering
                }
                if isHovering {
                    syncPendingDeleteInput()
                }
            }
            .onTapGesture {
                viewModel.selectDeleteRange(id: nil)
            }
        }
        .frame(height: deleteTrackAreaHeight)
    }

    private var deleteTrackAreaHeight: CGFloat {
        let inputHeight: CGFloat = shouldShowDeleteInputBubble ? 40 : 0
        let bubblesHeight: CGFloat = viewModel.deleteRanges.isEmpty ? 0 : 32
        return 42 + inputHeight + bubblesHeight
    }

    private var shouldShowDeleteInputBubble: Bool {
        isDeleteTrackHovered
    }

    private var deleteInputBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.bubble.fill")
                .font(.caption)
                .foregroundStyle(Color.cyan.opacity(0.92))
            Text(L10n.tr("legacy.key_149"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.9))

            Text(L10n.tr("legacy.key_12"))
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.7))
            TextField("0", text: $pendingDeleteStartText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)

            Text(L10n.tr("legacy.key_13"))
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.7))
            TextField("10", text: $pendingDeleteEndText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)

            Button(L10n.tr("video.delete.confirm")) {
                viewModel.addDeleteRange(startText: pendingDeleteStartText, endText: pendingDeleteEndText)
                syncPendingDeleteInput()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.cyan.opacity(0.32), lineWidth: 1)
        )
    }

    private var deleteRangeBubblesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.deleteRanges) { range in
                    deleteRangeBubble(range: range)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func deleteRangeBubble(range: CutRange) -> some View {
        let start = viewModel.deleteRangeStartSeconds(for: range.id)
        let end = viewModel.deleteRangeEndSeconds(for: range.id)
        let isSelected = viewModel.selectedDeleteRangeID == range.id
        let label = L10n.f(
            "fmt.video.delete_bubble_range",
            String(format: "%.2f", start),
            String(format: "%.2f", end)
        )

        return HStack(spacing: 6) {
            Text("🫧")
                .font(.caption)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
            Button {
                viewModel.removeDeleteRange(id: range.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.cyan.opacity(0.28) : Color.white.opacity(0.13))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isSelected ? Color.cyan.opacity(0.92) : Color.white.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            viewModel.selectDeleteRange(id: range.id)
        }
    }

    private func syncPendingDeleteInput() {
        if let selected = viewModel.selectedDeleteRange {
            pendingDeleteStartText = String(format: "%.3f", selected.start.seconds)
            pendingDeleteEndText = String(format: "%.3f", selected.end.seconds)
            return
        }
        let suggested = viewModel.suggestedDeleteRangeInput(defaultLength: 5.0)
        pendingDeleteStartText = suggested.start
        pendingDeleteEndText = suggested.end
    }

    private func deleteRangeChip(range: CutRange, trackWidth: CGFloat) -> some View {
        let duration = max(viewModel.sourceDuration, 0.001)
        let start = viewModel.deleteRangeStartSeconds(for: range.id)
        let end = viewModel.deleteRangeEndSeconds(for: range.id)
        let startText = String(format: "%.2f", start)
        let endText = String(format: "%.2f", end)
        let deleteTip = L10n.f("fmt.video.delete_tip_range", startText, endText)
        let startRatio = CGFloat(start / duration)
        let endRatio = CGFloat(end / duration)
        let x = trackWidth * startRatio
        let width = max(18, trackWidth * max(0, endRatio - startRatio))
        let isSelected = viewModel.selectedDeleteRangeID == range.id

        return HStack(spacing: 0) {
            handleView(systemName: "chevron.left.2", trackWidth: trackWidth) { delta in
                let nextStart = start + delta * duration
                viewModel.updateDeleteRange(id: range.id, start: nextStart)
            }

            Rectangle()
                .fill(Color.red.opacity(isSelected ? 0.75 : 0.55))
                .overlay(
                    Text("\(startText)s - \(endText)s")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .padding(.horizontal, 6),
                    alignment: .center
                )
                .onTapGesture {
                    viewModel.selectDeleteRange(id: range.id)
                }

            handleView(systemName: "chevron.right.2", trackWidth: trackWidth) { delta in
                let nextEnd = end + delta * duration
                viewModel.updateDeleteRange(id: range.id, end: nextEnd)
            }
        }
        .frame(width: width, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.cyan.opacity(0.9) : Color.white.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        )
        .help(deleteTip)
        .contextMenu {
            Button(L10n.tr("legacy.key_35")) {
                viewModel.selectDeleteRange(id: range.id)
                viewModel.removeDeleteRange(id: range.id)
            }
        }
        .position(x: x + width / 2, y: 21)
    }

    private func handleView(systemName: String, trackWidth: CGFloat, onDragDeltaRatio: @escaping (Double) -> Void) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: 14, height: 30)
            .background(Color.black.opacity(0.22))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let deltaRatio = value.translation.width / max(trackWidth, 1)
                        onDragDeltaRatio(Double(deltaRatio))
                    }
            )
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(L10n.tr("legacy.key_186"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 0)

                Button(viewModel.isApplyingCrop ? L10n.tr("legacy.key_46") : L10n.tr("legacy.key_126")) {
                    viewModel.executeCropAndReload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExecuteCrop)
            }

            VStack(spacing: 10) {
                ForEach(Array(aspectGridRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ForEach(row) { preset in
                            aspectCard(for: preset)
                        }
                        if row.count < 4 {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button(L10n.tr("legacy.key_215")) {
                    viewModel.resetCropRect()
                }
                .buttonStyle(.bordered)

                if viewModel.isCropNoOp {
                    Text(L10n.tr("legacy.key_103"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
                .padding(.vertical, 4)

            audioSection

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: 380)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
    }

    private func aspectCard(for preset: VideoCuttingAspectPreset) -> some View {
        let selected = preset == viewModel.selectedAspectPreset
        return Button {
            viewModel.selectAspectPresetWithReset(preset)
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1.2)
                    .frame(width: 32, height: 20)
                Text(preset.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .frame(width: 80, height: 80)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.cyan.opacity(0.95) : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("legacy.key_45"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.92))

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(L10n.tr("legacy.key_193"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.78))

                    Toggle("", isOn: Binding(
                        get: { viewModel.isNoiseReductionEnabled },
                        set: { viewModel.updateNoiseReductionEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!viewModel.hasAudioTrack)

                    Spacer(minLength: 0)

                    Text("\(Int(viewModel.noiseReductionPercent.rounded())) %")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.82))
                }

                Slider(
                    value: Binding(
                        get: { viewModel.noiseReductionPercent },
                        set: { viewModel.updateNoiseReductionPercent($0) }
                    ),
                    in: 0...100,
                    step: viewModel.noiseReductionStep
                )
                .tint(Color.cyan.opacity(0.9))
                .disabled(!viewModel.hasAudioTrack || !viewModel.isNoiseReductionEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                Text(L10n.tr("legacy.key_44"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                Spacer(minLength: 0)
                Picker(
                    "",
                    selection: Binding(
                        get: { viewModel.selectedAudioEQPreset },
                        set: { viewModel.updateAudioEQPreset($0) }
                    )
                ) {
                    ForEach(VideoCuttingAudioEQPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!viewModel.hasAudioTrack)
                .frame(width: 170)
            }

            if !viewModel.hasAudioTrack {
                Text(L10n.tr("legacy.key_174"))
                    .font(.caption)
                    .foregroundStyle(Color.orange.opacity(0.86))
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(L10n.tr("legacy.key_214")) {
                viewModel.importByPanel()
            }
            .buttonStyle(.bordered)

            if let exportURL = viewModel.exportURL {
                Button(L10n.tr("legacy.key_122")) {
                    viewModel.revealExport()
                }
                .buttonStyle(.bordered)
                .help(exportURL.path)
            }

            Text(viewModel.statusMessage)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.64))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(viewModel.isExporting ? L10n.tr("legacy.key_56") : L10n.tr("legacy.key_55")) {
                viewModel.exportTrimmedVideo()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canExport)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.19, green: 0.20, blue: 0.23))
    }

    private func dismissCuttingWindow() {
        viewModel.pausePlayback()
        if let windowID {
            dismissWindow(id: windowID)
        } else {
            dismissWindow()
        }
    }

    private func updateWindowTitle() {
#if os(macOS)
        let title = L10n.tr("legacy.key_157")
        NSApp.windows
            .filter { $0.identifier?.rawValue == windowID || $0.title == title || $0.title == "Smart Cutting" || $0.title == "智能裁剪" }
            .forEach { $0.title = title }
#endif
    }
}

#if os(macOS)
private struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostingView {
        let view = PlayerLayerHostingView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostingView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private final class PlayerLayerHostingView: NSView {
    override var isFlipped: Bool { true }

    var player: AVPlayer? {
        didSet {
            updatePlayerLayer()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        updatePlayerLayer()
    }

    private func updatePlayerLayer() {
        (layer as? AVPlayerLayer)?.player = player
    }
}
#endif
