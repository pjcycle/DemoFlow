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
    private let cropResizeHotspotDiameter: CGFloat = 50
    private let cropInteractionCoordinateSpace = "videoCuttingCropInteractionSpace"
    private let cropInteractionABMode: CropInteractionABMode = .normal
    private let modalMinWidth: CGFloat = 1120
    private let modalMinHeight: CGFloat = 720
    private let sidePanelWidth: CGFloat = 352
    private let aspectCardSize: CGFloat = 72
    private let deleteTrackHeight: CGFloat = 96
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

                Text("/")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
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
                Image(systemName: "checkmark")
                    .font(.headline.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help(L10n.tr("video.delete.input.apply"))
            .disabled(viewModel.isBusy)

            Spacer(minLength: 0)

            Text(L10n.tr("video.delete.track_hint"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.58))

            Button(viewModel.isExporting ? L10n.tr("legacy.key_46") : L10n.tr("video.delete.action.delete_current")) {
                viewModel.deleteActiveRangeAndReload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDeleteActiveRangeAndReload)
        }
    }

    private var deleteTrackArea: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                deleteTrackBackground(width: proxy.size.width, height: deleteTrackHeight)

                deleteTrackPlayhead(width: proxy.size.width, height: deleteTrackHeight)

                if let range = viewModel.activeDeleteRange {
                    deleteSelectionOverlay(
                        range: range,
                        trackWidth: proxy.size.width,
                        trackHeight: deleteTrackHeight
                    )
                } else {
                    Text(L10n.tr("video.delete.track_hint"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.42))
                        .padding(.horizontal, 12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(deleteTrackDragGesture(trackWidth: proxy.size.width))
        }
        .frame(height: deleteTrackHeight)
    }

    private func deleteTrackBackground(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.24)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if viewModel.timelineThumbnails.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            } else {
                HStack(spacing: 2) {
                    ForEach(viewModel.timelineThumbnails) { thumbnail in
                        Image(decorative: thumbnail.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                }
                .padding(2)
            }
        }
        .frame(width: width, height: height)
    }

    private func deleteTrackPlayhead(width: CGFloat, height: CGFloat) -> some View {
        let ratio = min(max(viewModel.playbackPosition / max(viewModel.sourceDuration, 0.001), 0), 1)
        return Rectangle()
            .fill(Color.cyan.opacity(0.95))
            .frame(width: 2, height: height)
            .shadow(color: Color.cyan.opacity(0.35), radius: 4)
            .offset(x: max(0, min(width - 2, width * ratio)))
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
            Button(L10n.tr("video.delete.action.delete_current")) {
                viewModel.deleteActiveRangeAndReload()
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
