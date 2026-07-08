//
//  AudioTrimWorkbenchView.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import SwiftUI
import UniformTypeIdentifiers

struct AudioTrimWorkbenchView: View {
    @ObservedObject var viewModel: AudioTrimViewModel

    var body: some View {
        trimWorkbenchCard
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewModel.isDropTargeted, perform: viewModel.handleDrop)
    }

    private var trimWorkbenchCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                toolbarRow

                waveformCanvas
                    .frame(height: 130)

                HStack(spacing: 10) {
                    if let range = viewModel.draft.activeRange {
                        timePill("\(formatTime(range.startTime)) - \(formatTime(range.endTime))")
                    } else {
                        timePill(L10n.tr("audio.trim.waveform.no_selection"))
                    }
                    infoPill(title: L10n.tr("audio.trim.info.selection"), value: selectionDurationText)
                    infoPill(title: L10n.tr("audio.trim.info.output_duration"), value: viewModel.totalOutputDurationText)
                }

                HStack(alignment: .center, spacing: 12) {
                    Text(L10n.tr("audio.trim.export.name"))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 64, alignment: .leading)

                    TextField(
                        L10n.tr("audio.trim.export.placeholder"),
                        text: Binding(
                            get: { viewModel.draft.exportFileName },
                            set: { viewModel.draft.exportFileName = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button {
                        viewModel.exportTrimmedAudio()
                    } label: {
                        Label(L10n.tr("audio.trim.action.export"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canExport)
                }
            }
        }
    }

    private var toolbarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text(L10n.tr("audio.trim.waveform.title"))
                    .font(.headline)

                Button {
                    viewModel.presentImporter()
                } label: {
                    Label(L10n.tr("audio.import.action.choose_file"), systemImage: "waveform.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.playPause()
                } label: {
                    Image(systemName: viewModel.previewStatus == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canPlay)
                .help(viewModel.previewStatus == .playing ? L10n.tr("audio.trim.action.pause") : L10n.tr("audio.trim.action.play"))

                Button {
                    viewModel.stopPlayback()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canPlay)
                .help(L10n.tr("audio.trim.action.stop"))

                timePill(viewModel.playheadTimeText)

                Button {
                    viewModel.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedPreparedAsset == nil)
                .help(L10n.tr("audio.trim.action.zoom_out"))

                Button {
                    viewModel.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedPreparedAsset == nil)
                .help(L10n.tr("audio.trim.action.zoom_in"))

                Button {
                    viewModel.resetZoom()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedPreparedAsset == nil)
                .help(L10n.tr("audio.trim.action.reset_zoom"))

                Button {
                    viewModel.applyTrimToEditor()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canApplyTrimToEditor)
                .help(L10n.tr("audio.trim.action.apply"))

                Button {
                    viewModel.resetEditor()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canReset)
                .help(L10n.tr("audio.trim.action.reset"))

                exportAvailabilityBadge
                statusPill(viewModel.statusMessage)
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var waveformCanvas: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let samples = viewModel.draft.waveformSamples
            let zoom = max(viewModel.draft.zoomLevel, 1)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(viewModel.isDropTargeted ? Color.orange.opacity(0.10) : Color.black.opacity(0.04))

                if !samples.isEmpty {
                    waveformBars(samples: samples, width: width, height: height, zoom: zoom)

                    if let range = viewModel.draft.activeRange,
                       let duration = viewModel.selectedPreparedAsset?.duration,
                       duration > 0 {
                        let startX = CGFloat(range.startTime / duration) * width
                        let endX = CGFloat(range.endTime / duration) * width
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.18))
                            .frame(width: max(endX - startX, 2), height: height)
                            .offset(x: startX)
                    }

                    if let duration = viewModel.selectedPreparedAsset?.duration, duration > 0 {
                        let x = CGFloat(viewModel.draft.playheadTime / duration) * width
                        Rectangle()
                            .fill(Color.red.opacity(0.75))
                            .frame(width: 2, height: height)
                            .offset(x: min(max(x, 0), width - 2))
                    }
                } else {
                    importDropZone
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragSelectionGesture(totalWidth: width))
            .contextMenu {
                if viewModel.draft.activeRange != nil && viewModel.canApplyTrimToEditor {
                    Button {
                        viewModel.deleteSelectedRange()
                    } label: {
                        Label(L10n.tr("audio.trim.action.delete_selection"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var importDropZone: some View {
        Button {
            viewModel.presentImporter()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.18))

                Text(L10n.tr("audio.trim.import.drop"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(L10n.tr("audio.trim.import.supported"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(viewModel.isDropTargeted ? Color.orange.opacity(0.10) : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        viewModel.isDropTargeted ? Color.orange.opacity(0.45) : Color.black.opacity(0.10),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 6])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.04)))
    }

    private var exportAvailabilityBadge: some View {
        Group {
            switch viewModel.exportAvailability {
            case let .allowed(formatLabel):
                badge(text: L10n.f("audio.trim.export.available", formatLabel), color: .green)
            case let .blocked(reason):
                badge(text: reason, color: .orange)
            }
        }
    }

    private var selectionDurationText: String {
        if let range = viewModel.draft.activeRange {
            return formatTime(range.duration)
        }
        return "--"
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 6, y: 3)
    }

    @ViewBuilder
    private func timePill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.05)))
    }

    @ViewBuilder
    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    @ViewBuilder
    private func infoPill(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.05)))
    }

    @ViewBuilder
    private func waveformBars(samples: [CGFloat], width: CGFloat, height: CGFloat, zoom: CGFloat) -> some View {
        let spacing: CGFloat = 2
        let count = max(samples.count, 1)
        let barWidth = max((width - CGFloat(count - 1) * spacing) / CGFloat(count), 1)

        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.84), Color.blue.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: barWidth, height: max(sample * height * 0.75 * zoom, 6))
            }
        }
        .frame(width: width, height: height, alignment: .center)
    }

    private func dragSelectionGesture(totalWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let duration = viewModel.selectedPreparedAsset?.duration, duration > 0 else { return }
                let startRatio = min(max(value.startLocation.x / totalWidth, 0), 1)
                let endRatio = min(max(value.location.x / totalWidth, 0), 1)
                viewModel.setActiveRange(
                    start: Double(startRatio) * duration,
                    end: Double(endRatio) * duration
                )
            }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
