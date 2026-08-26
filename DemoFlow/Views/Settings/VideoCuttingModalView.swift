//
//  VideoCuttingModalView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private struct TimelinePlayheadMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct VideoCuttingModalView: View {
    private enum CropInteractionABMode {
        case normal
        case resizeOnly
        case moveOnly
    }

    private enum DeleteTrackDragMode {
        case create
        case move
        case trimStart
        case trimEnd
    }

    private struct DeleteTrackDragContext {
        let mode: DeleteTrackDragMode
        let gestureStartSeconds: Double
        let initialRangeStart: Double
        let initialRangeEnd: Double
    }

    @ObservedObject var viewModel: VideoCuttingViewModel
    @ObservedObject var appCoordinator: AppCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    let windowID: String?

    @State private var cropDragStartRect: CGRect?
    @State private var hoveredCropHandle: VideoCropHandle?
    @State private var activeDragHandle: VideoCropHandle?
    @State private var deleteTrackDragContext: DeleteTrackDragContext?
    @State private var playheadDragStartPosition: Double?
    @State private var draggedTimelineClipID: UUID?
    @State private var hoveredTimelineClipID: UUID?
    @State private var timelineClipDragTranslation: CGFloat = 0
    @State private var timelineClipDragStartSeconds: Double?
    @State private var timelineClipDragDidMove = false
    private let cropResizeHotspotDiameter: CGFloat = 50
    private let cropInteractionCoordinateSpace = "videoCuttingCropInteractionSpace"
    private let timelineClipCoordinateSpace = "videoCuttingTimelineClipCoordinateSpace"
    private let cropInteractionABMode: CropInteractionABMode = .normal
    private let modalMinWidth: CGFloat = 1120
    private let modalMinHeight: CGFloat = 720
    private let sidePanelWidth: CGFloat = 352
    private let aspectCardSize: CGFloat = 72
    private let deleteTrackHeight: CGFloat = 96
    private let timelineRulerHeight: CGFloat = 34
    private let timelinePlayheadWidth: CGFloat = 18
    private let timelineVideoTrackHeight: CGFloat = 86
    private let timelineClipGap: CGFloat = 5
    private let deleteTrackHandleHitWidth: CGFloat = 14
    private let deleteTrackMinimumSelectionWidth: CGFloat = 48
    private let importDropZoneSize = CGSize(width: 600, height: 360)

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
        .frame(minWidth: modalMinWidth, minHeight: modalMinHeight)
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
            viewModel.autoImportLatestRecentRecordingIfNeeded()
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
        .frame(width: importDropZoneSize.width, height: importDropZoneSize.height)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .foregroundStyle(Color.white.opacity(0.2))
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contextMenu {
            Button(L10n.tr("legacy.key_54")) {
                viewModel.importByPanel()
            }
        }
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
            .contextMenu {
                Button(L10n.tr("video.cut.source.remove")) {
                    viewModel.clearImportedVideo()
                }
                if let sourceURL = viewModel.sourceURL {
                    Button(L10n.tr("video.cut.source.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                    }
                }
                Button(L10n.tr("legacy.key_54")) {
                    viewModel.importByPanel()
                }
            }
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
                .allowsHitTesting(!viewModel.hasTimelineEdits && !viewModel.isBusy)
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
            deleteTrackToolbar
            deleteTrackArea
            playbackToolbar
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.62))
    }

    private var playbackToolbar: some View {
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

            Text("/")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.45))
            Text(viewModel.totalDurationText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))

            Button {
                viewModel.completeTimelineEditsAndReload()
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.cyan.opacity(0.95))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("video.cut.timeline.commit_reload"))
            .disabled(!viewModel.canCompleteTimelineEdits)

            Spacer(minLength: 0)
        }
    }

    private var deleteTrackToolbar: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("legacy.key_12"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.62))

            TextField("0", text: $viewModel.keepStartText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 88)
                .onSubmit {
                    viewModel.applyQuickKeepRangeInput()
                }

            Text(L10n.tr("legacy.key_13"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.62))

            TextField("0", text: $viewModel.keepEndText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 88)
                .onSubmit {
                    viewModel.applyQuickKeepRangeInput()
                }

            Button {
                viewModel.applyQuickKeepRangeInput()
            } label: {
                Image(systemName: "return")
                    .font(.headline.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .help(L10n.tr("video.delete.input.apply"))
            .disabled(viewModel.isBusy)

            Spacer(minLength: 0)

            Button {
                viewModel.undoTimelineEdit()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.headline.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("video.cut.timeline.undo"))
            .disabled(!viewModel.canUndoTimelineEdit)

            Button {
                viewModel.redoTimelineEdit()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.headline.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("video.cut.timeline.redo"))
            .disabled(!viewModel.canRedoTimelineEdit)

            Button {
                viewModel.splitTimelineAtPlayhead()
            } label: {
                Image(systemName: "scissors")
                    .rotationEffect(.degrees(90))
                    .font(.headline.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("video.cut.timeline.split"))
            .disabled(!viewModel.canSplitAtPlayhead)

            Button {
                viewModel.togglePlaybackMute()
            } label: {
                Image(systemName: viewModel.isPlaybackMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.headline.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("video.cut.timeline.preview_mute"))
            .disabled(!viewModel.hasSource)

            Button {
                if viewModel.canDeleteSelectedTimelineClip {
                    viewModel.deleteSelectedTimelineClip()
                } else {
                    viewModel.deleteActiveRange()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.red.opacity(0.95))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canDeleteSelectedTimelineClip && !viewModel.canDeleteActiveRange)
        }
    }

    private var deleteTrackArea: some View {
        GeometryReader { proxy in
            let mediaWidth = max(proxy.size.width - timelinePlayheadWidth, 1)
            let dropZoneWidth = mediaWidth
            let timelineLeadingInset = timelinePlayheadWidth / 2
            let contentWidth = mediaWidth + dropZoneWidth + timelineLeadingInset
            let totalHeight = timelineRulerHeight + timelineVideoTrackHeight

            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        timelineRuler(width: mediaWidth)
                        timelineBlankRuler(width: dropZoneWidth)
                    }
                    .offset(x: timelineLeadingInset)

                    timelineVideoTrack(width: mediaWidth, dropZoneWidth: dropZoneWidth)
                        .offset(x: timelineLeadingInset)
                        .offset(y: timelineRulerHeight)

                    if let range = viewModel.activeDeleteRange {
                        deleteSelectionOverlay(
                            range: range,
                            trackWidth: mediaWidth,
                            trackHeight: timelineVideoTrackHeight
                        )
                        .allowsHitTesting(viewModel.timelineClips.count <= 1)
                        .offset(x: timelineLeadingInset, y: timelineRulerHeight)
                    }

                    Color.white.opacity(0.001)
                        .frame(width: mediaWidth, height: timelineVideoTrackHeight)
                        .contentShape(Rectangle())
                        .gesture(deleteTrackDragGesture(trackWidth: mediaWidth))
                        .allowsHitTesting(viewModel.timelineClips.count <= 1)
                        .offset(x: timelineLeadingInset, y: timelineRulerHeight)

                    timelineBoundaryOverlay(mediaWidth: mediaWidth, trackHeight: timelineVideoTrackHeight)
                        .offset(x: timelineLeadingInset, y: timelineRulerHeight)

                    deleteTrackPlayhead(
                        width: mediaWidth,
                        height: totalHeight,
                        rulerHeight: timelineRulerHeight
                    )
                    .offset(x: timelineLeadingInset)
                }
                .frame(width: contentWidth, height: totalHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            }
            .frame(height: totalHeight)
        }
        .frame(height: timelineRulerHeight + timelineVideoTrackHeight)
    }

    private func timelineRuler(width: CGFloat) -> some View {
        let duration = max(viewModel.sourceDuration, 0.001)
        let step = timelineRulerStep(for: duration)
        let tickCount = max(1, Int(ceil(duration / step)))

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.06))

            ForEach(0...tickCount, id: \.self) { index in
                let seconds = min(Double(index) * step, duration)
                let tickX = CGFloat(seconds / duration) * width
                let labelX = min(max(tickX, 14), max(14, width - 14))

                Text(formatTimelineTick(seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.78))
                    .fixedSize()
                    .position(x: labelX, y: 8)

                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 1, height: 8)
                    .position(x: tickX, y: timelineRulerHeight - 4)
            }

            ForEach(0..<tickCount, id: \.self) { index in
                let intervalStart = min(Double(index) * step, duration)
                let intervalEnd = min(Double(index + 1) * step, duration)
                let interval = intervalEnd - intervalStart

                ForEach(1..<5, id: \.self) { minorIndex in
                    let seconds = intervalStart + interval * Double(minorIndex) / 5
                    if seconds < duration {
                        let tickX = CGFloat(seconds / duration) * width
                        Rectangle()
                            .fill(Color.white.opacity(0.30))
                            .frame(width: 1, height: 4)
                            .position(x: tickX, y: timelineRulerHeight - 2)
                    }
                }
            }
        }
        .frame(width: width, height: timelineRulerHeight)
    }

    private func timelineBlankRuler(width: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.025))
                .overlay(
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.white.opacity(0.14))
                )
            Text(L10n.tr("video.cut.timeline.drop_zone"))
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.34))
        }
        .frame(width: width, height: timelineRulerHeight)
    }

    private func timelineVideoTrack(width: CGFloat, dropZoneWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.82))
                ForEach(Array(viewModel.timelineClips.enumerated()), id: \.element.id) { index, clip in
                    let frame = timelineClipFrame(
                        for: clip,
                        index: index,
                        mediaWidth: width
                    )
                    let isDragging = draggedTimelineClipID == clip.id
                    let dragOffset = isDragging ? timelineClipDragTranslation : 0
                    timelineClipView(
                        clip,
                        index: index,
                        width: frame.width,
                        height: timelineVideoTrackHeight - 4
                    )
                        .frame(width: frame.width, height: timelineVideoTrackHeight - 4)
                        .position(
                            x: frame.originX + frame.width / 2 + dragOffset,
                            y: 2 + (timelineVideoTrackHeight - 4) / 2
                        )
                        .zIndex(isDragging ? 5 : 1)
                        .allowsHitTesting(false)
                }

                timelineClipGapOverlay(width: width, height: timelineVideoTrackHeight)
                timelineClipEditOverlay(width: width, height: timelineVideoTrackHeight)

                Color.white.opacity(0.001)
                    .frame(width: width, height: timelineVideoTrackHeight)
                    .contentShape(Rectangle())
                    .gesture(timelineTrackGesture(mediaWidth: width))
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard draggedTimelineClipID == nil else { return }
                        switch phase {
                        case let .active(location):
                            hoveredTimelineClipID = timelineClipID(
                                at: location.x,
                                mediaWidth: width
                            )
                        case .ended:
                            hoveredTimelineClipID = nil
                        }
                    }
                    .contextMenu {
                        if let clipID = hoveredTimelineClipID,
                           viewModel.timelineClips.contains(where: { $0.id == clipID }) {
                            Button {
                                viewModel.deleteTimelineClip(clipID)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    .zIndex(10)
            }
            .frame(width: width, height: timelineVideoTrackHeight)
            .clipped()
            .coordinateSpace(name: timelineClipCoordinateSpace)
            timelineBlankDropZone(width: dropZoneWidth, height: timelineVideoTrackHeight)
        }
    }

    private func timelineBlankDropZone(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.025))
                .overlay(
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        .foregroundStyle(Color.white.opacity(0.14))
                )
            Image(systemName: "arrow.right.to.line.compact")
                .foregroundStyle(Color.white.opacity(0.24))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                viewModel.insertVideoAtPlayheadByPanel()
            } label: {
                Label(
                    L10n.tr("video.cut.timeline.add_video"),
                    systemImage: "plus.rectangle.on.rectangle"
                )
            }
        }
    }

    private func timelineClipGapOverlay(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(viewModel.timelineClips.dropLast().enumerated()), id: \.element.id) { _, clip in
            let duration = max(viewModel.sourceDuration, 0.001)
            let clipStart = viewModel.timelineStartSeconds(for: clip) ?? 0
            let endX = width * (clipStart + clip.durationSeconds) / duration
            Rectangle()
                .fill(Color.black.opacity(0.96))
                .frame(width: timelineClipGap, height: height - 4)
                .offset(x: endX - timelineClipGap / 2, y: 2)
                .allowsHitTesting(false)
        }
    }

    private func timelineTrackGesture(mediaWidth: CGFloat) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .local
        )
            .onChanged { value in
                if draggedTimelineClipID == nil {
                    guard let clipID = timelineClipID(
                        at: value.startLocation.x,
                        mediaWidth: mediaWidth
                    ) else {
                        return
                    }
                    draggedTimelineClipID = clipID
                    viewModel.selectTimelineClip(clipID)
                    hoveredTimelineClipID = clipID
                    timelineClipDragStartSeconds = viewModel.timelineClips
                        .first(where: { $0.id == clipID })
                        .flatMap { viewModel.timelineStartSeconds(for: $0) }
                        ?? 0
                }
                guard draggedTimelineClipID != nil else { return }
                timelineClipDragTranslation = value.translation.width
                if abs(value.translation.width) >= 6 {
                    timelineClipDragDidMove = true
                }
            }
            .onEnded { value in
                guard let clipID = draggedTimelineClipID,
                      let clip = viewModel.timelineClips.first(where: { $0.id == clipID }) else {
                    draggedTimelineClipID = nil
                    timelineClipDragTranslation = 0
                    timelineClipDragStartSeconds = nil
                    timelineClipDragDidMove = false
                    return
                }
                if timelineClipDragDidMove || abs(value.translation.width) >= 6 {
                    let initialStart = timelineClipDragStartSeconds
                        ?? viewModel.timelineStartSeconds(for: clip)
                        ?? 0
                    let delta = Double(value.translation.width / max(mediaWidth, 1)) * viewModel.sourceDuration
                    viewModel.finishTimelineClipDrag(
                        clipID,
                        desiredStartSeconds: initialStart + delta
                    )
                } else {
                    viewModel.selectTimelineClip(clipID)
                    hoveredTimelineClipID = clipID
                }
                draggedTimelineClipID = nil
                timelineClipDragTranslation = 0
                timelineClipDragStartSeconds = nil
                timelineClipDragDidMove = false
            }
    }

    @ViewBuilder
    private func timelineClipEditOverlay(width: CGFloat, height: CGFloat) -> some View {
        let selectedID = draggedTimelineClipID ?? hoveredTimelineClipID
        if let selectedID,
           let clip = viewModel.timelineClips.first(where: { $0.id == selectedID }) {
            let duration = max(viewModel.sourceDuration, 0.001)
            let storedStart = viewModel.timelineStartSeconds(for: clip) ?? 0
            let dragDelta = draggedTimelineClipID == selectedID
                ? Double(timelineClipDragTranslation / max(width, 1)) * viewModel.sourceDuration
                : 0
            let start = max(0, storedStart + dragDelta)
            let startX = width * start / duration
            let endX = width * (start + clip.durationSeconds) / duration
            let labelX = min(max((startX + endX) / 2, 78), max(78, width - 78))

            Rectangle()
                .fill(Color.cyan.opacity(0.92))
                .frame(width: 2, height: height)
                .offset(x: startX - 1)
                .shadow(color: Color.cyan.opacity(0.4), radius: 3)
                .overlay(alignment: .top) {
                    TimelinePlayheadMarker()
                        .fill(Color.cyan.opacity(0.98))
                        .frame(width: 15, height: 11)
                        .offset(x: 0, y: -3)
                }
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.cyan.opacity(0.92))
                .frame(width: 2, height: height)
                .offset(x: endX - 1)
                .shadow(color: Color.cyan.opacity(0.4), radius: 3)
                .overlay(alignment: .top) {
                    TimelinePlayheadMarker()
                        .fill(Color.cyan.opacity(0.98))
                        .frame(width: 15, height: 11)
                        .offset(x: 0, y: -3)
                }
                .allowsHitTesting(false)

            Text(timelineClipEditLabel(clip))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.78))
                .overlay(
                    Capsule()
                        .stroke(Color.cyan.opacity(0.85), lineWidth: 1)
                )
                .clipShape(Capsule())
                .position(x: labelX, y: 12)
                .allowsHitTesting(false)
                .zIndex(6)
        }
    }

    private func timelineBoundaryOverlay(mediaWidth: CGFloat, trackHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(viewModel.timelineClips.enumerated()), id: \.element.id) { _, clip in
                let clipStart = viewModel.timelineStartSeconds(for: clip) ?? 0
                let x = mediaWidth * (clipStart + clip.durationSeconds) / max(viewModel.sourceDuration, 0.001)
                Rectangle()
                    .fill(Color.orange.opacity(0.95))
                    .frame(width: 2, height: trackHeight)
                    .offset(x: x - 1)
                    .shadow(color: Color.orange.opacity(0.35), radius: 3)
                Image(systemName: "scissors")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.orange.opacity(0.98))
                    .background(Color.black.opacity(0.72).clipShape(Circle()))
                    .offset(x: x - 8, y: -7)
            }
        }
        .allowsHitTesting(false)
        .zIndex(3)
    }

    private func timelineClipFrame(
        for clip: VideoTimelineClip,
        index: Int,
        mediaWidth: CGFloat
    ) -> (originX: CGFloat, width: CGFloat) {
        let duration = max(viewModel.sourceDuration, 0.001)
        let rawWidth = max(3, mediaWidth * clip.durationSeconds / duration)
        let hasPreviousClip = index > 0
        let hasNextClip = index < viewModel.timelineClips.count - 1
        let leftInset = hasPreviousClip ? timelineClipGap / 2 : 0
        let rightInset = hasNextClip ? timelineClipGap / 2 : 0
        let visualWidth = max(3, rawWidth - leftInset - rightInset)
        let clipStart = viewModel.timelineStartSeconds(for: clip) ?? 0
        let originX = mediaWidth * clipStart / duration + leftInset
        return (originX, visualWidth)
    }

    private func timelineClipID(at locationX: CGFloat, mediaWidth: CGFloat) -> UUID? {
        for (index, clip) in viewModel.timelineClips.enumerated() {
            let frame = timelineClipFrame(
                for: clip,
                index: index,
                mediaWidth: mediaWidth
            )
            if locationX >= frame.originX,
               locationX <= frame.originX + frame.width {
                return clip.id
            }
        }
        return nil
    }

    private func timelineClipView(
        _ clip: VideoTimelineClip,
        index: Int,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let thumbnails = viewModel.timelineClipThumbnails[clip.id] ?? []
        let isSelected = viewModel.selectedTimelineClipID == clip.id
        return ZStack(alignment: .bottomLeading) {
            if thumbnails.isEmpty {
                Color.white.opacity(0.08)
            } else {
                let thumbnailWidth = width / CGFloat(max(thumbnails.count, 1))
                HStack(spacing: 0) {
                    ForEach(thumbnails) { thumbnail in
                        Image(decorative: thumbnail.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: thumbnailWidth, height: height)
                            .clipped()
                    }
                }
            }

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    isSelected ? Color.yellow.opacity(0.98) : Color.cyan.opacity(0.72),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(draggedTimelineClipID == clip.id ? 0.45 : 1)
        .help(timelineClipTooltip(clip, index: index))
    }

    private func timelineClipTooltip(_ clip: VideoTimelineClip, index: Int) -> String {
        let start = formatSeconds(clip.sourceStartSeconds)
        let end = formatSeconds(clip.sourceEndSeconds)
        let duration = formatSeconds(clip.durationSeconds)
        return L10n.f(
            "fmt.video.cut.timeline.clip_detail",
            index + 1,
            start,
            end,
            duration
        )
    }

    private func timelineClipEditLabel(_ clip: VideoTimelineClip) -> String {
        L10n.f(
            "fmt.video.cut.timeline.clip_edit",
            formatSeconds(clip.sourceStartSeconds),
            formatSeconds(clip.sourceEndSeconds)
        )
    }

    private func deleteTrackPlayhead(
        width: CGFloat,
        height: CGFloat,
        rulerHeight: CGFloat
    ) -> some View {
        let ratio = min(max(viewModel.playbackPosition / max(viewModel.sourceDuration, 0.001), 0), 1)
        let playheadWidth = timelinePlayheadWidth
        let lineX = min(max(width * ratio, 0), width)

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.red.opacity(0.95))
                .frame(width: 2, height: max(0, height - rulerHeight))
                .shadow(color: Color.red.opacity(0.45), radius: 4)
                .padding(.top, rulerHeight)

            TimelinePlayheadMarker()
                .fill(Color.red.opacity(0.98))
                .frame(width: playheadWidth, height: 14)
            .offset(y: rulerHeight - 5)
        }
        .frame(width: playheadWidth, height: height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if playheadDragStartPosition == nil {
                        playheadDragStartPosition = viewModel.playbackPosition
                    }
                    let delta = Double(value.translation.width / max(width, 1)) * viewModel.sourceDuration
                    viewModel.seek(to: (playheadDragStartPosition ?? 0) + delta)
                }
                .onEnded { _ in
                    playheadDragStartPosition = nil
                }
        )
        .offset(x: max(-playheadWidth / 2, min(width - playheadWidth / 2, lineX - playheadWidth / 2)))
        .zIndex(4)
    }

    private func deleteSelectionOverlay(
        range: CutRange,
        trackWidth: CGFloat,
        trackHeight: CGFloat
    ) -> some View {
        let metrics = deleteSelectionMetrics(for: range, trackWidth: trackWidth)
        let startText = formatSeconds(range.start.seconds)
        let endText = formatSeconds(range.end.seconds)
        let durationText = formatSeconds(range.durationSeconds)

        return HStack(spacing: 0) {
            deleteTrackHandle(systemName: "line.3.horizontal.decrease")

            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(Color.red.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 0, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
                .overlay(alignment: .center) {
                    if metrics.width > 120 {
                        Text("\(startText) - \(endText)  ·  \(durationText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.95))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                    }
                }

            deleteTrackHandle(systemName: "line.3.horizontal")
        }
        .frame(width: metrics.width, height: trackHeight)
        .background(Color.red.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.95), lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button {
                viewModel.deleteActiveRange()
            } label: {
                Image(systemName: "trash")
            }
            Button {
                viewModel.insertVideoAtPlayheadByPanel()
            } label: {
                Label(
                    L10n.tr("video.cut.timeline.add_video"),
                    systemImage: "plus.rectangle.on.rectangle"
                )
            }
        }
        .offset(x: metrics.originX)
    }

    private func deleteTrackHandle(systemName: String) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.28))
            Image(systemName: systemName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.88))
                .rotationEffect(.degrees(90))
        }
        .frame(width: 14)
    }

    private func deleteSelectionMetrics(for range: CutRange, trackWidth: CGFloat) -> (originX: CGFloat, width: CGFloat) {
        let duration = max(viewModel.sourceDuration, 0.001)
        let startRatio = min(max(range.start.seconds / duration, 0), 1)
        let endRatio = min(max(range.end.seconds / duration, 0), 1)
        let startX = trackWidth * startRatio
        let endX = trackWidth * endRatio
        let actualWidth = max(endX - startX, 1)
        let visualWidth = max(actualWidth, deleteTrackMinimumSelectionWidth)
        let centeredOrigin = ((startX + endX) / 2) - (visualWidth / 2)
        let originX = max(0, min(trackWidth - visualWidth, centeredOrigin))
        return (originX, visualWidth)
    }

    private func deleteTrackDragGesture(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let context = deleteTrackDragContext
                    ?? resolveDeleteTrackDragContext(
                        at: value.startLocation.x,
                        trackWidth: trackWidth
                    )
                deleteTrackDragContext = context
                updateDeleteTrackSelection(
                    with: context,
                    currentLocationX: value.location.x,
                    trackWidth: trackWidth
                )
            }
            .onEnded { value in
                defer { deleteTrackDragContext = nil }
                guard let context = deleteTrackDragContext else { return }
                let currentSeconds = deleteTrackSeconds(at: value.location.x, trackWidth: trackWidth)
                let minimumDuration = max(viewModel.frameDurationSeconds, 0.05)

                if context.mode == .create,
                   abs(currentSeconds - context.gestureStartSeconds) < minimumDuration {
                    viewModel.clearActiveDeleteRange()
                }
            }
    }

    private func resolveDeleteTrackDragContext(
        at locationX: CGFloat,
        trackWidth: CGFloat
    ) -> DeleteTrackDragContext {
        let gestureStartSeconds = deleteTrackSeconds(at: locationX, trackWidth: trackWidth)

        guard let activeRange = viewModel.activeDeleteRange else {
            return DeleteTrackDragContext(
                mode: .create,
                gestureStartSeconds: gestureStartSeconds,
                initialRangeStart: gestureStartSeconds,
                initialRangeEnd: gestureStartSeconds
            )
        }

        let metrics = deleteSelectionMetrics(for: activeRange, trackWidth: trackWidth)
        let rangeEndX = metrics.originX + metrics.width

        let mode: DeleteTrackDragMode
        if abs(locationX - metrics.originX) <= deleteTrackHandleHitWidth {
            mode = .trimStart
        } else if abs(locationX - rangeEndX) <= deleteTrackHandleHitWidth {
            mode = .trimEnd
        } else if locationX >= metrics.originX && locationX <= rangeEndX {
            mode = .move
        } else {
            mode = .create
        }

        return DeleteTrackDragContext(
            mode: mode,
            gestureStartSeconds: gestureStartSeconds,
            initialRangeStart: activeRange.start.seconds,
            initialRangeEnd: activeRange.end.seconds
        )
    }

    private func updateDeleteTrackSelection(
        with context: DeleteTrackDragContext,
        currentLocationX: CGFloat,
        trackWidth: CGFloat
    ) {
        let currentSeconds = deleteTrackSeconds(at: currentLocationX, trackWidth: trackWidth)
        let minimumDuration = max(viewModel.frameDurationSeconds, 0.05)

        switch context.mode {
        case .create:
            viewModel.setActiveDeleteRange(start: context.gestureStartSeconds, end: currentSeconds)
        case .move:
            let duration = max(context.initialRangeEnd - context.initialRangeStart, minimumDuration)
            let delta = currentSeconds - context.gestureStartSeconds
            let nextStart = max(0, min(context.initialRangeStart + delta, viewModel.sourceDuration - duration))
            viewModel.setActiveDeleteRange(start: nextStart, end: nextStart + duration)
        case .trimStart:
            let maxStart = context.initialRangeEnd - minimumDuration
            let nextStart = min(max(currentSeconds, 0), maxStart)
            viewModel.updateActiveDeleteRange(start: nextStart, end: context.initialRangeEnd)
        case .trimEnd:
            let minEnd = context.initialRangeStart + minimumDuration
            let nextEnd = max(min(currentSeconds, viewModel.sourceDuration), minEnd)
            viewModel.updateActiveDeleteRange(start: context.initialRangeStart, end: nextEnd)
        }
    }

    private func deleteTrackSeconds(at locationX: CGFloat, trackWidth: CGFloat) -> Double {
        guard viewModel.sourceDuration > 0 else { return 0 }
        let ratio = min(max(locationX / max(trackWidth, 1), 0), 1)
        return Double(ratio) * viewModel.sourceDuration
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let safe = max(0, Int(seconds.rounded(.down)))
        let hours = safe / 3600
        let minutes = (safe % 3600) / 60
        let secs = safe % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func timelineRulerStep(for duration: Double) -> Double {
        switch duration {
        case ...60:
            return 5
        case ...180:
            return 10
        case ...600:
            return 30
        case ...1800:
            return 60
        case ...3600:
            return 300
        default:
            return 600
        }
    }

    private func formatTimelineTick(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        if minutes == 0 {
            return L10n.f("video.cut.timeline.seconds", remainder)
        }
        if remainder == 0 {
            return L10n.f("video.cut.timeline.minutes", minutes)
        }
        return L10n.f("video.cut.timeline.minute_seconds", minutes, remainder)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(L10n.tr("legacy.key_186"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 0)

                Button {
                    viewModel.executeCropAndReload()
                } label: {
                    Image(systemName: viewModel.isApplyingCrop ? "hourglass" : "crop")
                        .font(.headline.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("legacy.key_126"))
                .disabled(!viewModel.canExecuteCrop)
            }

            VStack(spacing: 10) {
                ForEach(Array(aspectGridRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
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
                Button {
                    viewModel.resetCropRect()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.headline.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("legacy.key_215"))
                .disabled(viewModel.hasTimelineEdits || viewModel.isBusy)

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
        .frame(width: sidePanelWidth)
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
                    .frame(width: 28, height: 18)
                Text(preset.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .frame(width: aspectCardSize, height: aspectCardSize)
            .background(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.cyan.opacity(0.95) : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.hasTimelineEdits || viewModel.isBusy)
        .help(
            viewModel.hasTimelineEdits
                ? L10n.tr("video.cut.timeline.commit_required_for_crop")
                : preset.title
        )
    }

    private var exportSizeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.tr("video.cut.export_size.title"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                exportSizeModeButton(.source, titleKey: "video.cut.export_size.mode.default")
                exportSizeModeButton(.custom, titleKey: "video.cut.export_size.mode.custom")

                if appCoordinator.resolvedLanguage == .zhHans {
                    Text(L10n.tr("video.cut.export_size.video_size"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }

                Text(viewModel.currentRealSizeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if viewModel.isUsingCustomExportSize {
                HStack(spacing: 8) {
                    TextField(
                        L10n.tr("video.cut.export_size.width"),
                        text: $viewModel.customExportWidthText
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)

                    Text("×")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.68))

                    TextField(
                        L10n.tr("video.cut.export_size.height"),
                        text: $viewModel.customExportHeightText
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)

                    Spacer(minLength: 0)
                }
            }

            if let validationMessage = viewModel.exportSizeValidationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orange.opacity(0.9))
            }
        }
    }

    private func exportSizeModeButton(
        _ mode: VideoCuttingExportSizeMode,
        titleKey: String
    ) -> some View {
        let isSelected = viewModel.exportSizeMode == mode
        return Button {
            viewModel.setExportSizeMode(mode)
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.cyan.opacity(0.96) : Color.white.opacity(0.5))
                Text(L10n.tr(titleKey))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
            }
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

            if viewModel.hasSource {
                exportSizeControls
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
