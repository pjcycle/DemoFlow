import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubDubSettingsView: View {
    @ObservedObject var viewModel: SubDubViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            tabBar

            switch viewModel.selectedTab {
            case .videoDubbing:
                VideoDubbingPanel(viewModel: viewModel.videoDubbingViewModel)
            case .aiVoiceover:
                AIVoiceoverPanel(viewModel: viewModel.aiVoiceoverViewModel)
            case .subtitleSync:
                SubtitleSyncPanel(viewModel: viewModel.subtitleSyncViewModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.9), Color.red.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("subdub.hero.title"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("subdub.hero.subtitle"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.90, green: 0.39, blue: 0.18), Color(red: 0.16, green: 0.45, blue: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 6)
    }

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(SubDubTab.allCases) { tab in
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    VStack(spacing: 8) {
                        Text(L10n.tr(tab.titleKey))
                            .font(.subheadline.weight(viewModel.selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(viewModel.selectedTab == tab ? .primary : .secondary)
                        Rectangle()
                            .fill(viewModel.selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }
}

private struct VideoDubbingPanel: View {
    @ObservedObject var viewModel: VideoDubbingViewModel

    private let dropTypes = [
        UTType.fileURL.identifier,
        UTType.movie.identifier,
        UTType.mpeg4Movie.identifier,
        UTType.quickTimeMovie.identifier
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.hasSource {
                HStack {
                    Label(viewModel.sourceURL?.lastPathComponent ?? "", systemImage: "film")
                        .lineLimit(1)
                    Spacer()
                    Text(viewModel.playbackPositionText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                SubDubPlayerView(player: viewModel.player)
                    .frame(minHeight: 280, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                SubDubTimelineRuler(
                    duration: viewModel.sourceDuration,
                    position: viewModel.playbackPosition
                )
                .frame(height: 26)

                SubDubWaveformView(
                    duration: viewModel.sourceDuration,
                    position: viewModel.playbackPosition,
                    waveformSamples: viewModel.waveformSamples
                )
                .frame(height: 72)

                HStack(spacing: 10) {
                    iconButton(
                        systemName: "mic",
                        help: L10n.tr("subdub.action.prepare"),
                        action: viewModel.prepareDubbing,
                        isDisabled: viewModel.state.isBusy
                    )

                    if viewModel.state == .ready || viewModel.state == .failed {
                        iconButton(
                            systemName: "record.circle",
                            help: L10n.tr("subdub.action.start_recording"),
                            action: viewModel.startRecording
                        )
                    }

                    if viewModel.state == .recording {
                        iconButton(
                            systemName: "pause.fill",
                            help: L10n.tr("subdub.action.pause_recording"),
                            action: viewModel.pauseRecording
                        )
                        iconButton(
                            systemName: "stop.fill",
                            help: L10n.tr("subdub.action.stop_recording"),
                            action: viewModel.stopRecording
                        )
                    }

                    if viewModel.state == .paused {
                        iconButton(
                            systemName: "play.fill",
                            help: L10n.tr("subdub.action.resume_recording"),
                            action: viewModel.continueRecording
                        )
                        iconButton(
                            systemName: "stop.fill",
                            help: L10n.tr("subdub.action.stop_recording"),
                            action: viewModel.stopRecording
                        )
                    }

                    iconButton(
                        systemName: "arrow.counterclockwise",
                        help: L10n.tr("subdub.action.rerecord"),
                        action: viewModel.resetRecording,
                        isDisabled: viewModel.state.isBusy
                    )

                    if viewModel.hasAudio {
                        iconButton(
                            systemName: viewModel.isPreviewPlaying ? "pause.fill" : "play.fill",
                            help: viewModel.isPreviewPlaying
                                ? L10n.tr("subdub.action.pause_dubbed_video")
                                : L10n.tr("subdub.action.play_dubbed_video"),
                            action: viewModel.toggleRecordedPreview
                        )
                        iconButton(
                            systemName: "arrow.down.circle",
                            help: L10n.tr("subdub.action.save_audio"),
                            action: viewModel.saveAudio
                        )
                        iconButtonWithBadge(
                            systemName: "waveform.and.mic",
                            help: L10n.tr("subdub.action.replace_audio"),
                            action: viewModel.exportVideo,
                            badge: L10n.tr("subscription.membership.vip"),
                            isDisabled: viewModel.state.isBusy
                        )
                    }
                    Spacer(minLength: 0)
                }
            } else {
                dropZone(
                    icon: "film",
                    text: L10n.tr("subdub.action.drop_video"),
                    action: viewModel.importVideoByPanel
                )
                .onDrop(of: dropTypes, isTargeted: nil) { providers in
                    viewModel.importDroppedProviders(providers)
                    return true
                }
            }

            statusText(viewModel.statusMessage)
        }
        .padding(16)
        .background(cardBackground)
    }
}

private struct AIVoiceoverPanel: View {
    @ObservedObject var viewModel: AIVoiceoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SecureField(L10n.tr("subdub.label.api_key"), text: $viewModel.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                iconButton(
                    systemName: "key.fill",
                    help: L10n.tr("subdub.action.save_api_key"),
                    action: viewModel.saveAPIKey
                )
            }

            HStack(spacing: 8) {
                iconButton(
                    systemName: "doc.text",
                    help: L10n.tr("subdub.action.import_text"),
                    action: viewModel.importTextByPanel
                )
                Text(viewModel.text.isEmpty ? L10n.tr("subdub.empty.no_text") : L10n.tr("subdub.status.text_ready"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(L10n.tr("subdub.label.text"))
                .font(.headline)
            TextEditor(text: $viewModel.text)
                .font(.body)
                .frame(minHeight: 140)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

            HStack(spacing: 12) {
                TextField(L10n.tr("subdub.label.voice"), text: $viewModel.selectedVoice)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Stepper(
                    value: $viewModel.speed,
                    in: 0.25...4.0,
                    step: 0.05
                ) {
                    Text("\(L10n.tr("subdub.label.speed")): \(viewModel.speed, specifier: "%.2f")")
                        .font(.caption)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                iconButton(
                    systemName: "sparkles",
                    help: L10n.tr("subdub.action.generate_tts"),
                    action: viewModel.generateTTS,
                    isDisabled: viewModel.state.isBusy
                )

                if viewModel.hasGeneratedAudio {
                    iconButton(
                        systemName: viewModel.isAudioPlaying ? "pause.fill" : "play.fill",
                        help: viewModel.isAudioPlaying ? L10n.tr("subdub.action.pause") : L10n.tr("subdub.action.play"),
                        action: viewModel.toggleAudioPreview
                    )
                    iconButton(
                        systemName: "arrow.down.circle",
                        help: L10n.tr("subdub.action.save_mp3"),
                        action: viewModel.saveMP3
                    )
                }
            }

            Divider()
            if viewModel.isPlayerReady {
                SubDubPlayerView(player: viewModel.player)
                    .frame(minHeight: 230, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    iconButton(
                        systemName: "play.fill",
                        help: L10n.tr("subdub.action.play"),
                        action: viewModel.togglePlayback
                    )
                    iconButton(
                        systemName: "film",
                        help: L10n.tr("subdub.action.import_video"),
                        action: viewModel.importVideoByPanel
                    )
                    Spacer()
                    Text(viewModel.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                iconButton(
                    systemName: "film",
                    help: L10n.tr("subdub.action.import_video"),
                    action: viewModel.importVideoByPanel
                )
            }

            if viewModel.hasGeneratedAudio && viewModel.isPlayerReady {
                iconButtonWithBadge(
                    systemName: "rectangle.stack.badge.play",
                    help: L10n.tr("subdub.action.merge_video"),
                    action: viewModel.mergeVideo,
                    badge: L10n.tr("subscription.membership.vip"),
                    isDisabled: viewModel.state.isBusy
                )
            }

            statusText(viewModel.statusMessage)
        }
        .padding(16)
        .background(cardBackground)
    }
}

private struct SubtitleSyncPanel: View {
    @ObservedObject var viewModel: SubtitleSyncViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                fileButton(
                    icon: "film",
                    title: L10n.tr("subdub.label.source_video"),
                    value: viewModel.videoURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video"),
                    action: viewModel.importVideoByPanel
                )
                fileButton(
                    icon: "waveform",
                    title: L10n.tr("subdub.label.audio"),
                    value: viewModel.audioURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_audio"),
                    action: viewModel.importAudioByPanel
                )
                fileButton(
                    icon: "captions.bubble",
                    title: L10n.tr("subdub.label.subtitle"),
                    value: viewModel.subtitleURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_subtitle"),
                    action: viewModel.importSubtitleByPanel
                )
            }

            if viewModel.isPlayerReady {
                SubDubPlayerView(player: viewModel.player)
                    .frame(minHeight: 280, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                iconButton(
                    systemName: "play.fill",
                    help: L10n.tr("subdub.action.play"),
                    action: viewModel.togglePlayback
                )
            }

            Text(viewModel.inputSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            iconButton(
                systemName: "rectangle.stack.badge.play",
                help: L10n.tr("subdub.action.export_video"),
                action: viewModel.export,
                isDisabled: !viewModel.canExport
            )

            statusText(viewModel.statusMessage)
        }
        .padding(16)
        .background(cardBackground)
        .onDrop(of: [UTType.fileURL.identifier, UTType.movie.identifier, UTType.audio.identifier, UTType.plainText.identifier], isTargeted: nil) { providers in
            viewModel.importDroppedProviders(providers)
            return true
        }
    }

    private func fileButton(icon: String, title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SubDubPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> SubDubPlayerHostingView {
        let view = SubDubPlayerHostingView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: SubDubPlayerHostingView, context: Context) {
        nsView.player = player
    }
}

private struct SubDubTimelineRuler: View {
    let duration: Double
    let position: Double

    private var tickStep: Double {
        switch duration {
        case ...30: return 5
        case ...120: return 10
        case ...300: return 30
        case ...600: return 60
        default: return 120
        }
    }

    private var tickValues: [Double] {
        guard duration > 0 else { return [0] }
        let step = tickStep
        var values = Array(stride(from: 0, through: duration, by: step))
        if let last = values.last, duration - last > 0.5 {
            values.append(duration)
        }
        return values
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = duration > 0
                ? min(max(position / duration, 0), 1)
                : 0

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .offset(y: 7)

                ForEach(tickValues, id: \.self) { value in
                    let tickProgress = duration > 0 ? value / duration : 0
                    let x = min(max(tickProgress * width, 18), max(width - 18, 18))
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.secondary.opacity(value.truncatingRemainder(dividingBy: 60) == 0 ? 0.8 : 0.45))
                            .frame(width: 1, height: value.truncatingRemainder(dividingBy: 60) == 0 ? 8 : 5)
                        Text(formatRulerTime(value))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .position(x: x, y: 16)
                }

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 12)
                    .position(x: progress * width, y: 7)
            }
            .padding(.horizontal, 8)
        }
    }

    private func formatRulerTime(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes > 0 {
            return remainingSeconds == 0
                ? "\(minutes)m"
                : "\(minutes)m\(remainingSeconds)s"
        }
        return "\(totalSeconds)s"
    }
}

private struct SubDubWaveformView: View {
    let duration: Double
    let position: Double
    let waveformSamples: [Double]

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let barCount = max(32, Int(size.width / 6))
                let progress = duration > 0
                    ? min(max(position / duration, 0), 1)
                    : 0
                let activeColor = Color.accentColor.opacity(0.9)
                let inactiveColor = Color.secondary.opacity(0.28)
                var baseline = Path()
                baseline.move(to: CGPoint(x: 8, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width - 8, y: size.height / 2))
                context.stroke(
                    baseline,
                    with: .color(Color.secondary.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [1, 3])
                )

                let peak = waveformSamples.max() ?? 0
                if peak > 0.02 {
                    for index in 0..<barCount {
                        let fraction = Double(index) / Double(max(barCount - 1, 1))
                        let start = min(
                            waveformSamples.count - 1,
                            Int(Double(index) / Double(barCount) * Double(waveformSamples.count))
                        )
                        let end = min(
                            waveformSamples.count,
                            max(start + 1, Int(Double(index + 1) / Double(barCount) * Double(waveformSamples.count)))
                        )
                        let value = waveformSamples[start..<end].max() ?? 0
                        let barHeight = min(size.height * 0.86, size.height * (0.04 + value * 0.82))
                        let x = CGFloat(fraction) * size.width
                        let rect = CGRect(
                            x: x,
                            y: (size.height - barHeight) / 2,
                            width: 2,
                            height: max(2, barHeight)
                        )
                        if value > 0.02 {
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 1),
                                with: .color(fraction <= progress ? activeColor : inactiveColor)
                            )
                        }
                    }
                }

                let playheadX = CGFloat(progress) * size.width
                var playhead = Path()
                playhead.move(to: CGPoint(x: playheadX, y: 0))
                playhead.addLine(to: CGPoint(x: playheadX, y: size.height))
                context.stroke(playhead, with: .color(Color.accentColor), lineWidth: 1.5)
            }
            .padding(.horizontal, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}

private final class SubDubPlayerHostingView: NSView {
    var player: AVPlayer? {
        didSet { (layer as? AVPlayerLayer)?.player = player }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        (layer as? AVPlayerLayer)?.player = player
    }
}

private func statusText(_ value: String) -> some View {
    Text(value)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

private func iconButton(
    systemName: String,
    help: String,
    action: @escaping () -> Void,
    isDisabled: Bool = false
) -> some View {
    Button(action: action) {
        Image(systemName: systemName)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.38 : 1)
}

private func iconButtonWithBadge(
    systemName: String,
    help: String,
    action: @escaping () -> Void,
    badge: String,
    isDisabled: Bool = false
) -> some View {
    Button(action: action) {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .frame(width: 22, height: 32)

            Text(badge)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.16))
                .clipShape(Capsule())
        }
        .frame(minWidth: 54, minHeight: 32, maxHeight: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.38 : 1)
}

private func dropZone(icon: String, text: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28))
            Text(text).font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
}

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
}
