import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct CompositionTimelinePlayheadMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct VideoCompositionPanel: View {
    @ObservedObject var viewModel: VideoCompositionViewModel
    let onImportVideos: () -> Void
    let onImportDroppedProviders: ([NSItemProvider]) -> Void
    let onRemoveVideo: () -> Void
    @State private var playheadDragStart: Double?
    @State private var selectionDragStart: Double?
    @State private var selectionDragEnd: Double?
    @State private var timelineDragClipID: UUID?
    @State private var timelineDragStartX: CGFloat?
    @State private var timelineDragTranslation: CGFloat = 0
    @State private var timelineDragDidMove = false
    @State private var isPlayheadHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.hasSource {
                HStack(alignment: .top, spacing: 14) {
                    controls
                    preview
                }
                .frame(height: subDubVideoPreviewMaxHeight + 30, alignment: .topLeading)
                timeline
            } else {
                emptyState
            }
            statusView
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onDrop(of: [UTType.movie.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers in
            onImportDroppedProviders(providers)
            return true
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.tr("subdub.video_composition.controls.title"), systemImage: "slider.horizontal.3")
                .font(.headline)

            Button { onImportVideos() } label: {
                Label(L10n.tr("subdub.video_composition.action.import"), systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExporting || viewModel.isGeneratingCover)

            Menu {
                Button {
                    viewModel.insertImageCoverByPanel()
                } label: {
                    Label(
                        L10n.tr("subdub.video_composition.cover.action.import_image"),
                        systemImage: "photo"
                    )
                }
                Button {
                    viewModel.insertCurrentFrameCover()
                } label: {
                    Label(
                        L10n.tr("subdub.video_composition.cover.action.current_frame"),
                        systemImage: "camera"
                    )
                }
            } label: {
                Label(
                    L10n.tr(viewModel.hasCover
                        ? "subdub.video_composition.cover.action.replace"
                        : "subdub.video_composition.cover.action.add"),
                    systemImage: "rectangle.on.rectangle"
                )
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isExporting || viewModel.isGeneratingCover)

            if viewModel.hasCover {
                HStack(spacing: 7) {
                    Label(
                        L10n.f("subdub.video_composition.cover.status.set", viewModel.coverDuration),
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                    Button { viewModel.locateCover() } label: {
                        Image(systemName: "location.fill")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("subdub.video_composition.cover.action.locate"))
                    Button { viewModel.removeCover() } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("subdub.video_composition.cover.action.remove"))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(spacing: 6) {
                Text(L10n.tr("subdub.video_composition.cover.duration"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("3", text: $viewModel.coverDurationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                Text(L10n.tr("subdub.video_composition.cover.seconds"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("subdub.video_composition.output.title"))
                    .font(.caption.weight(.semibold))
                Text(L10n.f("subdub.video_composition.output.detail", viewModel.outputSizeText, viewModel.frameRate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.f("subdub.video_composition.output.duration", viewModel.totalDurationText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button { viewModel.compose() } label: {
                Label(L10n.tr("subdub.video_composition.action.compose"), systemImage: "rectangle.stack.badge.play")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canCompose)

            if viewModel.outputURL != nil {
                Button { viewModel.revealOutput() } label: {
                    Label(L10n.tr("subdub.video_composition.action.reveal"), systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                Text(L10n.f("subdub.video_composition.progress", Int(viewModel.exportProgress * 100)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if viewModel.isGeneratingCover {
                ProgressView()
                Text(L10n.tr("subdub.video_composition.status.cover_generating"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 330, height: subDubVideoPreviewMaxHeight + 6, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.tr("subdub.video_composition.preview.title"), systemImage: "film")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.currentTimeText) / \(viewModel.totalDurationText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            let videoSize = subDubVideoPreviewSize(for: viewModel.sourceVideoSize)
            ZStack(alignment: .topLeading) {
                if viewModel.isPlayerReady {
                    CompositionPlayerView(player: viewModel.player)
                        .frame(width: videoSize.width, height: videoSize.height)
                } else {
                    Color.clear
                    Text(L10n.tr("subdub.video_composition.preview.unavailable"))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: subDubVideoPreviewMaxWidth, height: subDubVideoPreviewMaxHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: subDubVideoPreviewMaxWidth, height: subDubVideoPreviewMaxHeight + 30, alignment: .topLeading)
        .contextMenu {
            Button(L10n.tr("video.cut.source.remove")) {
                onRemoveVideo()
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineToolbar
            compositionTimelineTrack
            playbackToolbar
        }
        .padding(12)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var timelineToolbar: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("legacy.key_12"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("0", text: $viewModel.deleteStartText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onSubmit { viewModel.confirmSelectionRangeFromInputs() }
            Text(L10n.tr("legacy.key_13"))
            TextField("0", text: $viewModel.deleteEndText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onSubmit { viewModel.confirmSelectionRangeFromInputs() }
            Button { viewModel.confirmSelectionRangeFromInputs() } label: {
                Image(systemName: "return")
            }
            .buttonStyle(.plain)
            .help(L10n.tr("video.delete.input.apply"))
            .disabled(viewModel.isExporting)

            Spacer(minLength: 12)
            Button { viewModel.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain)
                .disabled(!viewModel.canUndo || viewModel.isExporting)
            Button { viewModel.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRedo || viewModel.isExporting)
            Button { viewModel.splitAtPlayhead() } label: {
                Image(systemName: "scissors")
                    .rotationEffect(.degrees(90))
            }
                .buttonStyle(.plain)
                .help(L10n.tr("subdub.video_composition.action.split"))
                .disabled(viewModel.isExporting)
            Button { viewModel.insertVideoAtPlayheadByPanel() } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.plain)
            .help(L10n.tr("subdub.video_composition.action.insert"))
            .disabled(viewModel.isExporting)
            Button { viewModel.togglePreviewMute() } label: {
                Image(systemName: viewModel.isPreviewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .help(L10n.tr("subdub.video_composition.action.mute"))
            Button { viewModel.deleteSelection() } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("subdub.video_composition.action.delete_selection"))
            .disabled(!viewModel.canDeleteSelection)
        }
    }

    private var compositionTimelineTrack: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - 18, 1)
            let duration = max(viewModel.sourceDuration, 0.001)
            let playheadX = min(max(width * CGFloat(viewModel.playbackPosition / duration), 0), width)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    timelineRuler(width: width, duration: duration)
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.86)
                            .frame(width: width, height: 82)
                        ForEach(Array(viewModel.timelineClips.enumerated()), id: \.element.id) { index, clip in
                            let clipWidth = max(3, width * CGFloat(clip.durationSeconds / duration))
                            let clipStart = viewModel.timelineStartSeconds(for: clip) ?? 0
                            compositionClipView(clip, index: index, width: clipWidth)
                                .frame(width: clipWidth, height: 82)
                                .clipped()
                                .offset(
                                    x: width * CGFloat(clipStart / duration)
                                        + (timelineDragClipID == clip.id ? timelineDragTranslation : 0)
                                )
                                .opacity(timelineDragClipID == clip.id && timelineDragDidMove ? 0.72 : 1)
                        }
                        Color.white.opacity(0.025)
                            .frame(width: 60, height: 82)
                            .offset(x: width + 8)
                            .onDrop(of: [UTType.text.identifier], isTargeted: nil) { _ in
                                if let selected = viewModel.selectedTimelineClipID { viewModel.moveTimelineClipToEnd(selected) }
                                return true
                            }
                    }
                    .frame(width: width, height: 82, alignment: .topLeading)
                    .frame(height: 82)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        timelineInteractionGesture(width: width, duration: duration)
                    )
                }
                .offset(x: 9)
                selectionOverlay(width: width, duration: duration)
                    .offset(x: 9)
                Rectangle()
                    .fill(Color.red.opacity(0.95))
                    .frame(width: 2, height: 82)
                    .offset(
                        // The line is 2px wide, so place its left edge one
                        // pixel before the visual center of the 18px marker.
                        x: playheadX + 8,
                        y: 34
                    )
                    .allowsHitTesting(false)
                CompositionTimelinePlayheadMarker()
                    .fill(Color.red)
                    .frame(width: 18, height: 12)
                    .offset(
                        // Position the marker by its left edge; its center
                        // then lands on the red line at playheadX + 9.
                        x: playheadX,
                        y: 29
                    )
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: 24, height: 116)
                    .contentShape(Rectangle())
                    .offset(x: playheadX - 3)
                    .onHover { isPlayheadHovered = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if playheadDragStart == nil { playheadDragStart = viewModel.playbackPosition }
                                let delta = Double(value.translation.width / width) * duration
                                viewModel.seek(to: (playheadDragStart ?? 0) + delta)
                            }
                            .onEnded { _ in playheadDragStart = nil }
                    )
                if isPlayheadHovered {
                    Button {
                        viewModel.insertVideoAtPlayheadByPanel()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white, .blue)
                            .shadow(color: .black.opacity(0.7), radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("subdub.video_composition.action.insert"))
                    .offset(
                        x: playheadX + 1,
                        y: 43
                    )
                    .zIndex(5)
                }
                if viewModel.hasCover {
                    Text(L10n.tr("subdub.video_composition.timeline.cover"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                        .offset(x: 12, y: 40)
                        .allowsHitTesting(false)
                        .zIndex(4)
                }
            }
        }
        .frame(height: 116)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14)))
    }

    private func timelineRuler(width: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .leading) {
            Color.white.opacity(0.06)
            // Keep one readable ruler.  A fixed 5-second tick produced
            // hundreds of labels for long videos, visually merging into a
            // second white strip and making the thumbnail track appear
            // overlapped.  Pick an interval that keeps roughly 8–12 labels.
            let interval = timelineRulerInterval(for: duration)
            let steps = max(1, Int(ceil(duration / interval)))
            ForEach(0...steps, id: \.self) { index in
                let seconds = min(Double(index) * interval, duration)
                let x = width * CGFloat(seconds / duration)
                Text(timelineRulerLabel(seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.72))
                    .position(x: min(max(x, 16), max(16, width - 16)), y: 10)
                Rectangle()
                    .fill(Color.white.opacity(0.42))
                    .frame(width: 1, height: 8)
                    .position(x: x, y: 27)
            }
        }
        .frame(width: width, height: 34, alignment: .leading)
    }

    private func timelineRulerInterval(for duration: Double) -> Double {
        let candidates: [Double] = [1, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return candidates.first(where: { duration / $0 <= 12 }) ?? 3600
    }

    private func timelineRulerLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%dh", total / 3600)
        }
        if total >= 60 {
            return String(format: "%dm", total / 60)
        }
        return "\(total)s"
    }

    private func compositionClipView(
        _ clip: VideoTimelineClip,
        index: Int,
        width: CGFloat
    ) -> some View {
        let thumbs = viewModel.timelineClipThumbnails[clip.id] ?? []
        return ZStack(alignment: .bottomLeading) {
            if thumbs.isEmpty { Color.white.opacity(0.09) }
            else {
                // Keep every thumbnail inside the clip's time-proportional
                // frame.  A fixed tile width makes short clips lose half of
                // their strip (the HStack is clipped by the clip frame) and
                // makes adjacent clips look like they overlap.  The clip
                // itself is still positioned by its absolute timeline start;
                // only the internal thumbnails are evenly distributed.
                let thumbnailWidth = max(1, width / CGFloat(thumbs.count))
                HStack(spacing: 0) {
                    ForEach(thumbs) { thumb in
                        Image(decorative: thumb.image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: thumbnailWidth, height: 82)
                            .clipped()
                    }
                }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            Text(clip.isCover
                ? L10n.tr("subdub.video_composition.timeline.cover")
                : L10n.f("subdub.video_composition.timeline.clip", index + 1))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(5)
        }
        .frame(maxHeight: 82)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(viewModel.selectedTimelineClipID == clip.id ? Color.yellow : Color.cyan.opacity(0.75), lineWidth: viewModel.selectedTimelineClipID == clip.id ? 2 : 1))
    }

    private func selectionOverlay(width: CGFloat, duration: Double) -> some View {
        let range = selectionDragRange ?? viewModel.selectedRange
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? 0
        let startX = width * CGFloat(max(0, min(start, duration)) / duration)
        let endX = width * CGFloat(max(0, min(end, duration)) / duration)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.yellow.opacity(range == nil ? 0 : 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.yellow.opacity(range == nil ? 0 : 0.92), lineWidth: 2)
            )
            .frame(width: max(1, endX - startX), height: 82)
            .offset(x: startX, y: 34)
            .allowsHitTesting(false)
    }

    private var selectionDragRange: ClosedRange<Double>? {
        guard let start = selectionDragStart, let end = selectionDragEnd else { return nil }
        return min(start, end)...max(start, end)
    }

    private func timelineInteractionGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if timelineDragStartX == nil {
                    timelineDragStartX = value.startLocation.x
                    let start = timelineSeconds(at: value.startLocation.x, width: width, duration: duration)
                    if let clipID = viewModel.timelineClipID(at: start) {
                        timelineDragClipID = clipID
                        viewModel.selectTimelineClip(clipID)
                    } else {
                        selectionDragStart = start
                        selectionDragEnd = start
                    }
                }

                let canMoveClip = timelineDragClipID.map { !viewModel.isCoverClip($0) } ?? false
                timelineDragTranslation = canMoveClip ? value.translation.width : 0
                if canMoveClip && abs(value.translation.width) >= 8 {
                    timelineDragDidMove = true
                }
                if timelineDragClipID == nil {
                    selectionDragEnd = timelineSeconds(
                        at: value.location.x,
                        width: width,
                        duration: duration
                    )
                }
            }
            .onEnded { value in
                let start = timelineSeconds(at: value.startLocation.x, width: width, duration: duration)
                let end = timelineSeconds(at: value.location.x, width: width, duration: duration)

                if let clipID = timelineDragClipID {
                    if timelineDragDidMove {
                        viewModel.moveTimelineClip(clipID, toTimelineSeconds: end)
                    } else {
                        viewModel.selectTimelineClip(clipID)
                    }
                } else if timelineDragDidMove {
                    viewModel.selectRange(start: start, end: end)
                }

                selectionDragStart = nil
                selectionDragEnd = nil
                timelineDragClipID = nil
                timelineDragStartX = nil
                timelineDragTranslation = 0
                timelineDragDidMove = false
            }
    }

    private func timelineSeconds(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return Double(max(0, min(x, width)) / width) * duration
    }

    private var playbackToolbar: some View {
        HStack(spacing: 12) {
            Button { viewModel.togglePlayback() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text(viewModel.currentTimeText).font(.system(.body, design: .monospaced)).foregroundStyle(.cyan)
            Text("/").foregroundStyle(.secondary)
            Text(viewModel.totalDurationText).font(.system(.body, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 0)
            Text(L10n.f("subdub.video_composition.timeline.count", viewModel.timelineClips.count))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("subdub.video_composition.title"), systemImage: "rectangle.stack.badge.play")
                .font(.headline)
            Text(L10n.tr("subdub.video_composition.placeholder"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button { onImportVideos() } label: {
                Label(L10n.tr("subdub.video_composition.action.import"), systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var statusView: some View {
        Text(viewModel.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

private struct CompositionPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> CompositionPlayerHostingView {
        let view = CompositionPlayerHostingView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: CompositionPlayerHostingView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

private final class CompositionPlayerHostingView: NSView {
    var player: AVPlayer? {
        didSet { (layer as? AVPlayerLayer)?.player = player }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = 8
        layer.masksToBounds = true
        return layer
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        guard let playerLayer = layer as? AVPlayerLayer else { return }
        playerLayer.cornerRadius = 8
        playerLayer.masksToBounds = true
        playerLayer.player = player
    }
}
