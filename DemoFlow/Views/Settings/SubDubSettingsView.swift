import AVFoundation
import AVKit
import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

private let subDubConfigurationContentWidth: CGFloat = 330

/// Single source of truth for the right-column video preview so all four
/// panels (video dubbing / video conversion / subtitle burn / audio
/// replacement) keep the same size when the user switches tabs.
private let subDubVideoPreviewMaxWidth: CGFloat = 520
private let subDubVideoPreviewMaxHeight: CGFloat = 320
private let subDubVideoPreviewPlaceholder: CGSize = CGSize(width: 520, height: 292.5)

func subDubVideoPreviewSize(for sourceSize: CGSize) -> CGSize {
    guard sourceSize.width > 0, sourceSize.height > 0 else {
        return subDubVideoPreviewPlaceholder
    }
    let aspectRatio = sourceSize.width / sourceSize.height
    let width = min(subDubVideoPreviewMaxWidth, subDubVideoPreviewMaxHeight * aspectRatio)
    return CGSize(width: width, height: width / aspectRatio)
}

struct SubDubSettingsView: View {
    @ObservedObject var viewModel: SubDubViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroBanner
            tabBar

            switch viewModel.selectedTab {
            case .videoDubbing:
                VideoDubbingPanel(
                    viewModel: viewModel.videoDubbingViewModel,
                    onImportVideo: viewModel.importVideoByPanel,
                    onImportDroppedProviders: viewModel.importDroppedProviders,
                    onRemoveVideo: viewModel.removeSharedVideo
                )
            case .videoConversion:
                VideoConversionPanel(
                    viewModel: viewModel.videoConversionViewModel,
                    watermarkViewModel: viewModel.watermarkRemovalViewModel,
                    onImportVideo: viewModel.importVideoForConversionByPanel,
                    onImportDroppedProviders: viewModel.importDroppedProviders,
                    onRemoveVideo: viewModel.removeSharedVideo,
                    onLoadConvertedVideo: viewModel.importConvertedVideoIntoSharedSession
                )
            case .subtitleBurning:
                SubtitleBurnPanel(
                    viewModel: viewModel.subtitleBurnViewModel,
                    onImportVideo: viewModel.importVideoByPanel,
                    onImportDroppedProviders: viewModel.importDroppedProviders,
                    onRemoveVideo: viewModel.removeSharedVideo
                )
            case .audioReplacement:
                AudioReplacementPanel(
                    viewModel: viewModel.audioReplacementViewModel,
                    onImportVideo: viewModel.importVideoByPanel,
                    onImportDroppedProviders: viewModel.importDroppedProviders,
                    onRemoveVideo: viewModel.removeSharedVideo
                )
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

private struct VideoConversionPanel: View {
    @ObservedObject var viewModel: VideoConvertViewModel
    @ObservedObject var watermarkViewModel: WatermarkRemovalViewModel
    let onImportVideo: () -> Void
    let onImportDroppedProviders: ([NSItemProvider]) -> Void
    let onRemoveVideo: () -> Void
    let onLoadConvertedVideo: () -> Void

    private let dropTypes = [
        UTType.fileURL.identifier,
        UTType.movie.identifier,
        UTType.mpeg4Movie.identifier,
        UTType.quickTimeMovie.identifier,
        UTType.data.identifier
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.hasSource {
                HStack(alignment: .top, spacing: 14) {
                    controls
                    activeVideoPreview
                        .frame(
                            minHeight: conversionConfigurationContentHeight,
                            alignment: .topLeading
                        )
                }
                activeAudioTrack
            } else {
                emptyState
            }
            statusText(activeStatusMessage)
        }
        .padding(16)
        .background(cardBackground)
        .sheet(isPresented: $watermarkViewModel.isWatermarkLibraryPresented) {
            WatermarkReplacementLibrarySheet(viewModel: watermarkViewModel)
        }
        .onDrop(of: dropTypes, isTargeted: nil) { providers in
            onImportDroppedProviders(providers)
            return true
        }
    }

    private var activeStatusMessage: String {
        viewModel.selectedMode == .watermarkRemoval
            ? watermarkViewModel.statusMessage
            : viewModel.statusMessage
    }

    private var sourceHeader: some View {
        HStack(spacing: 10) {
            Label(viewModel.sourceName, systemImage: "film")
                .lineLimit(1)
            Spacer()
            Text(L10n.f("subdub.video_conversion.source_duration", viewModel.sourceDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if watermarkViewModel.canExportCurrentVideo {
                Button {
                    watermarkViewModel.exportCurrentVideo()
                } label: {
                    Label(
                        L10n.tr("subdub.watermark.action.export_current"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(watermarkViewModel.isExportingCurrentVideo)
            }
            iconButton(
                systemName: "arrow.triangle.2.circlepath",
                help: L10n.tr("subdub.action.reselect_video"),
                action: onImportVideo,
                isDisabled: viewModel.state.isBusy || watermarkViewModel.state.isBusy
            )
            iconButton(
                systemName: "xmark.circle",
                help: L10n.tr("subdub.action.remove_video"),
                action: onRemoveVideo,
                isDisabled: viewModel.state.isBusy || watermarkViewModel.state.isBusy
            )
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $viewModel.selectedMode) {
                ForEach(VideoConversionMode.allCases) { mode in
                    Text(L10n.tr(mode.titleKey)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(viewModel.state.isBusy || watermarkViewModel.state.isBusy)

            ScrollView(.vertical, showsIndicators: true) {
                if viewModel.selectedMode == .formatConversion {
                    formatConversionControls
                } else {
                    watermarkControls
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            width: subDubConfigurationContentWidth,
            height: conversionConfigurationContentHeight,
            alignment: .topLeading
        )
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var formatConversionControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(L10n.tr("subdub.video_conversion.current_format"))
                    .font(.headline)
                Text(viewModel.sourceFormatTitle)
                    .font(.headline.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("subdub.video_conversion.output_format"))
                    .font(.headline)
                Picker("", selection: $viewModel.selectedFormat) {
                    ForEach(VideoConversionFormat.allCases) { format in
                        Text(L10n.tr(format.titleKey)).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            DisclosureGroup(L10n.tr("subdub.video_conversion.advanced")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("subdub.video_conversion.quality"))
                        .font(.headline)
                    Picker("", selection: $viewModel.selectedQuality) {
                        ForEach(VideoConversionQualityPreset.allCases) { quality in
                            Text(L10n.tr(quality.titleKey)).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    viewModel.startConversion()
                } label: {
                    Label(
                        L10n.tr("subdub.video_conversion.action.start"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.state.isBusy)

                if viewModel.state.isBusy {
                    Button {
                        viewModel.cancelCurrentTask()
                    } label: {
                        Label(
                            L10n.tr("subdub.video_conversion.action.stop"),
                            systemImage: "stop.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                if viewModel.outputURL != nil {
                    Button {
                        viewModel.revealOutput()
                    } label: {
                        Label(
                            L10n.tr("subdub.video_conversion.action.reveal"),
                            systemImage: "folder"
                        )
                    }
                    .buttonStyle(.bordered)

                    if viewModel.selectedFormat != .webm {
                        Button {
                            onLoadConvertedVideo()
                        } label: {
                            Label(
                                L10n.tr("subdub.video_conversion.action.load_shared"),
                                systemImage: "rectangle.stack.badge.plus"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if viewModel.state.isBusy || viewModel.progress > 0 {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                Text(L10n.f("subdub.video_conversion.progress", Int(viewModel.progress * 100)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var watermarkControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if watermarkViewModel.hasSource {
                HStack(spacing: 8) {
                    Button {
                        watermarkViewModel.openWatermarkLibrary()
                    } label: {
                        Label(
                            L10n.tr("subdub.watermark.library.action.manage"),
                            systemImage: "photo.stack"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(watermarkViewModel.state.isBusy)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        watermarkViewModel.addRegion()
                    } label: {
                        Label(L10n.tr("subdub.watermark.action.add_region"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(watermarkViewModel.state.isBusy)

                    Button {
                        watermarkViewModel.deleteSelectedRegion()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help(L10n.tr("subdub.watermark.action.delete_region"))
                    .disabled(watermarkViewModel.selectedRegionID == nil || watermarkViewModel.state.isBusy)

                    Button {
                        watermarkViewModel.clearRegions()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .help(L10n.tr("subdub.watermark.action.clear_regions"))
                    .disabled(watermarkViewModel.regions.isEmpty || watermarkViewModel.state.isBusy)
                }

                if !watermarkViewModel.regions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(watermarkViewModel.regions.enumerated()), id: \.element.id) { index, region in
                                Button {
                                    watermarkViewModel.selectRegionAndOpenLibrary(region.id)
                                } label: {
                                    Text(L10n.f("subdub.watermark.region_item", index + 1))
                                        .font(.caption.weight(region.id == watermarkViewModel.selectedRegionID ? .semibold : .regular))
                                }
                                .buttonStyle(.bordered)
                                .tint(region.id == watermarkViewModel.selectedRegionID ? .accentColor : .secondary)
                            }
                        }
                    }
                }

                DisclosureGroup(L10n.tr("subdub.video_conversion.advanced")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("subdub.video_conversion.quality"))
                            .font(.headline)
                        Picker("", selection: $watermarkViewModel.selectedQuality) {
                            ForEach(VideoConversionQualityPreset.allCases) { quality in
                                Text(L10n.tr(quality.titleKey)).tag(quality)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("subdub.watermark.repair.label"))
                            .font(.headline)
                        Picker("", selection: $watermarkViewModel.selectedRepairPreset) {
                            ForEach(WatermarkRepairPreset.allCases) { preset in
                                Text(L10n.tr(preset.titleKey)).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(watermarkViewModel.state.isBusy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button {
                        watermarkViewModel.previewCurrentFrame()
                    } label: {
                        Label(L10n.tr("subdub.watermark.action.preview_frame"), systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!watermarkViewModel.canPreviewFrame)

                    if watermarkViewModel.previewImage != nil {
                        Button {
                            watermarkViewModel.clearFramePreview()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .help(L10n.tr("subdub.watermark.action.show_original"))
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        watermarkViewModel.startRemoval()
                    } label: {
                        Label(L10n.tr("subdub.watermark.action.start"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!watermarkViewModel.canProcess)

                    if watermarkViewModel.state.isBusy {
                        Button {
                            watermarkViewModel.cancelCurrentTask()
                        } label: {
                            Label(L10n.tr("subdub.video_conversion.action.stop"), systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    if watermarkViewModel.outputURL != nil {
                        Button {
                            watermarkViewModel.revealOutput()
                        } label: {
                            Label(
                                L10n.tr("subdub.video_conversion.action.reveal"),
                                systemImage: "folder"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if watermarkViewModel.state.isBusy || watermarkViewModel.progress > 0 {
                    ProgressView(value: watermarkViewModel.progress)
                        .progressViewStyle(.linear)
                    Text(L10n.f("subdub.video_conversion.progress", Int(watermarkViewModel.progress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.tr("subdub.watermark.webm_unavailable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var conversionVideoSurfaceHeight: CGFloat {
        // Keep both modes at the same height so toggling between format
        // conversion and watermark removal does not jump the preview size.
        return 320
    }

    private var conversionConfigurationContentHeight: CGFloat {
        subDubVideoPreviewSize(for: watermarkViewModel.sourceVideoSize).height + 53
    }

    private var conversionVideoPreviewSize: CGSize {
        subDubVideoPreviewSize(for: watermarkViewModel.sourceVideoSize)
    }

    @ViewBuilder
    private var activeVideoPreview: some View {
        if viewModel.selectedMode == .watermarkRemoval {
            watermarkVideoPreview
        } else {
            formatVideoPreview
        }
    }

    private var formatVideoPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    viewModel.sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video"),
                    systemImage: "film"
                )
                .lineLimit(1)
                Spacer()
                Text(viewModel.playbackPositionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ZStack {
                if viewModel.isPlayerReady {
                    SubDubPlayerView(player: viewModel.player)
                } else {
                    Color.black.opacity(0.86)
                    Label(
                        L10n.tr("subdub.video_conversion.preview.unavailable"),
                        systemImage: "film"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                }
            }
            .frame(
                width: conversionVideoPreviewSize.width,
                height: conversionVideoPreviewSize.height,
                alignment: .leading
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contextMenu {
                Button(L10n.tr("subdub.action.remove_video")) {
                    onRemoveVideo()
                }
                Button(L10n.tr("subdub.action.reselect_video")) {
                    onImportVideo()
                }
            }

            HStack(spacing: 8) {
                iconButton(
                    systemName: viewModel.isPreviewPlaying ? "pause.fill" : "play.fill",
                    help: viewModel.isPreviewPlaying
                        ? L10n.tr("subdub.action.pause")
                        : L10n.tr("subdub.action.play"),
                    action: viewModel.togglePlayback,
                    isDisabled: !viewModel.isPlayerReady
                )
                Slider(
                    value: Binding(
                        get: { viewModel.playbackPosition },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(viewModel.sourceDuration, 0.1)
                )
                .disabled(!viewModel.isPlayerReady)
            }
        }
        .frame(width: 520, alignment: .topLeading)
    }

    private var watermarkVideoPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(watermarkViewModel.sourceName, systemImage: "film")
                    .lineLimit(1)
                Spacer()
                Text(watermarkViewModel.playbackPositionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            WatermarkVideoSurface(viewModel: watermarkViewModel)
                .frame(width: conversionVideoPreviewSize.width, height: conversionVideoPreviewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button(L10n.tr("subdub.action.remove_video")) { onRemoveVideo() }
                    Button(L10n.tr("subdub.action.reselect_video")) { onImportVideo() }
                }

            HStack(spacing: 8) {
                iconButton(
                    systemName: watermarkViewModel.isPreviewPlaying ? "pause.fill" : "play.fill",
                    help: watermarkViewModel.isPreviewPlaying ? L10n.tr("subdub.action.pause") : L10n.tr("subdub.action.play"),
                    action: watermarkViewModel.togglePlayback,
                    isDisabled: !watermarkViewModel.isPlayerReady || watermarkViewModel.state.isBusy
                )
                Slider(
                    value: Binding(
                        get: { watermarkViewModel.playbackPosition },
                        set: { watermarkViewModel.seek(to: $0) }
                    ),
                    in: 0...max(watermarkViewModel.sourceDuration, 0.1)
                )
                .disabled(!watermarkViewModel.isPlayerReady || watermarkViewModel.state.isBusy)
            }
        }
        .frame(width: 520, alignment: .topLeading)
    }

    @ViewBuilder
    private var activeAudioTrack: some View {
        if viewModel.selectedMode == .watermarkRemoval {
            watermarkAudioTrack
        } else {
            formatAudioTrack
        }
    }

    private var formatAudioTrack: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    L10n.tr("subdub.video_conversion.audio_track"),
                    systemImage: "waveform"
                )
                .font(.headline)
                Spacer()
                Text(viewModel.audioTrackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SubtitleBurnTimelineView(
                duration: viewModel.sourceDuration,
                position: viewModel.playbackPosition,
                sourceSamples: viewModel.sourceWaveformSamples,
                cues: [],
                selectedCueID: nil,
                onSeek: viewModel.seek
            )
        }
    }

    private var watermarkAudioTrack: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.tr("subdub.video_conversion.audio_track"), systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text(watermarkViewModel.audioTrackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SubtitleBurnTimelineView(
                duration: watermarkViewModel.sourceDuration,
                position: watermarkViewModel.playbackPosition,
                sourceSamples: watermarkViewModel.sourceWaveformSamples,
                cues: [],
                selectedCueID: nil,
                onSeek: watermarkViewModel.seek
            )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.tr("subdub.video_conversion.title"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.headline)
            Text(L10n.tr("subdub.video_conversion.placeholder"))
                .font(.callout)
                .foregroundStyle(.secondary)
            dropZone(
                icon: "film",
                text: L10n.tr("subdub.action.drop_video"),
                action: onImportVideo
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}

private struct WatermarkReplacementLibrarySheet: View {
    private enum Section: String, CaseIterable, Identifiable {
        case images
        case text

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .images: return "subdub.watermark.library.section.images"
            case .text: return "subdub.watermark.library.section.text"
            }
        }
    }

    @ObservedObject var viewModel: WatermarkRemovalViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: Section = .images
    @State private var selectedTextStyleID: UUID?
    @State private var editingTextStyle: WatermarkLibraryTextStyle?
    @State private var isDeleteImageConfirmationPresented = false
    @State private var imageToDelete: WatermarkLibraryImage?
    @State private var isDeleteTextConfirmationPresented = false
    @State private var textStyleToDelete: WatermarkLibraryTextStyle?

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 1.00, green: 0.44, blue: 0.40),
                                     Color(red: 0.97, green: 0.63, blue: 0.20)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(watermarkLibraryTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(L10n.tr("subdub.watermark.library.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.isWatermarkLibraryPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("subdub.action.close"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.watermarkLibraryAvailable {
            ContentUnavailableView(
                L10n.tr("subdub.watermark.library.workspace_title"),
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(L10n.tr("subdub.watermark.library.workspace_missing"))
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $selectedSection) {
                    ForEach(Section.allCases) { section in
                        Text(L10n.tr(section.titleKey)).tag(section)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Group {
                    if selectedSection == .images {
                        imageLibrary
                    } else {
                        textLibrary
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 580, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.reloadWatermarkLibrary() }
        .confirmationDialog(
            L10n.tr("subdub.watermark.library.delete_image.title"),
            isPresented: $isDeleteImageConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("subdub.action.delete"), role: .destructive) {
                if let imageToDelete { viewModel.deleteLibraryImage(imageToDelete.id) }
            }
        } message: {
            Text(L10n.tr("subdub.watermark.library.delete_image.message"))
        }
        .confirmationDialog(
            L10n.tr("subdub.watermark.library.delete_text.title"),
            isPresented: $isDeleteTextConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("subdub.action.delete"), role: .destructive) {
                if let textStyleToDelete { viewModel.deleteTextStyle(textStyleToDelete.id) }
            }
        } message: {
            Text(L10n.tr("subdub.watermark.library.delete_text.message"))
        }
    }

    private var imageLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    viewModel.importLibraryPNG()
                } label: {
                    Label(L10n.tr("subdub.watermark.library.action.import_image"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.revealWatermarkLibrary()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help(L10n.tr("subdub.watermark.library.action.reveal"))
                if viewModel.selectedRegion?.imageLibraryID != nil {
                    Button(L10n.tr("subdub.watermark.library.action.remove_from_region")) {
                        viewModel.removeLibraryImageFromSelectedRegion()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }

            Text(L10n.tr("subdub.watermark.library.image_limit_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.watermarkLibrary.images.isEmpty {
                ContentUnavailableView(
                    L10n.tr("subdub.watermark.library.images_empty"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(L10n.tr("subdub.watermark.library.images_empty_hint"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                        ForEach(viewModel.watermarkLibrary.images) { image in
                            imageCard(image)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func imageCard(_ image: WatermarkLibraryImage) -> some View {
        let isApplied = viewModel.selectedRegion?.imageLibraryID == image.id
        return ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let url = viewModel.imageLibraryURL(for: image),
               let previewImage = NSImage(contentsOf: url) {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isApplied ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isApplied ? 4 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(image.displayName)
        .onTapGesture {
            if isApplied {
                viewModel.removeLibraryImageFromSelectedRegion()
            } else {
                viewModel.applyLibraryImage(image.id)
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            imageToDelete = image
            isDeleteImageConfirmationPresented = true
        }
    }

    private var textLibrary: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List {
                    ForEach(Array(viewModel.watermarkLibrary.textStyles), id: \.id) { style in
                        Button {
                            if viewModel.selectedRegion?.textStyleID == style.id {
                                viewModel.removeTextStyleFromSelectedRegion()
                                editingTextStyle = nil
                                selectedTextStyleID = nil
                            } else {
                                viewModel.applyTextStyle(style.id)
                                editingTextStyle = style
                                selectedTextStyleID = style.id
                            }
                        } label: {
                            WatermarkTextStyleRow(
                                style: style,
                                isApplied: viewModel.selectedRegion?.textStyleID == style.id,
                                isSelected: selectedTextStyleID == style.id
                            )
                        }
                        .buttonStyle(WatermarkThumbnailButtonStyle())
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onLongPressGesture(minimumDuration: 0.5) {
                            textStyleToDelete = style
                            isDeleteTextConfirmationPresented = true
                        }
                    }

                    WatermarkTextStyleAddCard {
                        editingTextStyle = newTextStyle()
                        selectedTextStyleID = nil
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(width: 280, height: 400)
            }

            VStack(alignment: .leading, spacing: 10) {
                if let draft = editingTextStyle {
                    textEditor(style: draft)
                } else {
                    ContentUnavailableView(
                        L10n.tr("subdub.watermark.library.text_empty"),
                        systemImage: "textformat",
                        description: Text(L10n.tr("subdub.watermark.library.text_empty_hint"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func textEditor(style: WatermarkLibraryTextStyle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WatermarkTextStyleRow(
                style: style,
                isApplied: false,
                compact: true,
                fontSize: 18
            )
            .frame(maxWidth: .infinity)
            .frame(height: 150)

            TextField(L10n.tr("subdub.watermark.text.placeholder"), text: textBinding(style.id, \.text))
                .textFieldStyle(.roundedBorder)
            Picker(L10n.tr("subdub.watermark.text.font"), selection: textBinding(style.id, \.font)) {
                ForEach(WatermarkTextFont.allCases) { font in
                    Text(L10n.tr(font.titleKey)).tag(font)
                }
            }
            HStack(spacing: 8) {
                Text(L10n.tr("subdub.watermark.text.color")).font(.caption)
                ColorPicker("", selection: colorBinding(style.id), supportsOpacity: true)
                    .labelsHidden()
                Text(L10n.tr("subdub.watermark.text.opacity")).font(.caption)
                Slider(value: opacityBinding(style.id), in: 0...1)
            }
            Toggle(L10n.tr("subdub.watermark.text.outline"), isOn: textBinding(style.id, \.outlineEnabled))
            if editingTextStyle?.outlineEnabled == true {
                labeledSlider(L10n.tr("subdub.watermark.text.outline_width"), value: textBinding(style.id, \.outlineScale), range: 0.001...0.012)
            }
            Toggle(L10n.tr("subdub.watermark.text.shadow"), isOn: textBinding(style.id, \.shadowEnabled))
            if editingTextStyle?.shadowEnabled == true {
                labeledSlider(L10n.tr("subdub.watermark.text.shadow_offset"), value: textBinding(style.id, \.shadowOffsetScale), range: 0.001...0.02)
            }

            HStack(spacing: 8) {
                Button(L10n.tr("subdub.watermark.library.action.save_new_text")) {
                    guard let draft = editingTextStyle else { return }
                    var copy = draft
                    copy = WatermarkLibraryTextStyle(
                        name: copy.name,
                        text: copy.text,
                        font: copy.font,
                        color: copy.color,
                        outlineEnabled: copy.outlineEnabled,
                        outlineScale: copy.outlineScale,
                        shadowEnabled: copy.shadowEnabled,
                        shadowOffsetScale: copy.shadowOffsetScale
                    )
                    viewModel.saveTextStyle(copy)
                    selectedTextStyleID = copy.id
                    self.editingTextStyle = copy
                }
                .buttonStyle(.bordered)

                Button(L10n.tr("subdub.watermark.library.action.update_text")) {
                    guard let editingTextStyle, viewModel.watermarkLibrary.textStyles.contains(where: { $0.id == editingTextStyle.id }) else { return }
                    viewModel.saveTextStyle(editingTextStyle, replacingID: editingTextStyle.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.watermarkLibrary.textStyles.contains(where: { $0.id == style.id }))

                Spacer()
                if viewModel.watermarkLibrary.textStyles.contains(where: { $0.id == style.id }) {
                    Button(role: .destructive) {
                        textStyleToDelete = style
                        isDeleteTextConfirmationPresented = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help(L10n.tr("subdub.watermark.library.action.delete_text"))
                }
            }
            if viewModel.selectedRegion?.textStyleID != nil {
                Button(L10n.tr("subdub.watermark.library.action.remove_from_region")) {
                    viewModel.removeTextStyleFromSelectedRegion()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var watermarkLibraryTitle: String {
        guard let regionIndex = viewModel.selectedRegionIndex else {
            return L10n.tr("subdub.watermark.library.title.generic")
        }
        return L10n.f("subdub.watermark.library.title", regionIndex)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func textBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<WatermarkLibraryTextStyle, Value>) -> Binding<Value> {
        Binding(
            get: { editingTextStyle?[keyPath: keyPath] ?? newTextStyle()[keyPath: keyPath] },
            set: { value in editingTextStyle?[keyPath: keyPath] = value }
        )
    }

    private func opacityBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { editingTextStyle?.color.opacity ?? 1 },
            set: { value in editingTextStyle?.color.opacity = min(max(value, 0), 1) }
        )
    }

    private func colorBinding(_ id: UUID) -> Binding<Color> {
        Binding(
            get: {
                let color = editingTextStyle?.color ?? .white
                return Color(red: color.red, green: color.green, blue: color.blue, opacity: color.opacity)
            },
            set: { color in
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                editingTextStyle?.color = SubtitleThemeColor(
                    red: Double(resolved.redComponent),
                    green: Double(resolved.greenComponent),
                    blue: Double(resolved.blueComponent),
                    opacity: Double(resolved.alphaComponent)
                )
            }
        )
    }

    private func newTextStyle() -> WatermarkLibraryTextStyle {
        WatermarkLibraryTextStyle(name: L10n.tr("subdub.watermark.library.new_text_name"), text: "")
    }
}

private struct WatermarkTextStyleRow: View {
    let style: WatermarkLibraryTextStyle
    var isApplied: Bool = false
    var isSelected: Bool = false
    var compact: Bool = false
    var fontSize: CGFloat? = nil

    private var hasState: Bool { isApplied || isSelected }

    private var strokeColor: Color {
        if isApplied { return .green }
        if isSelected { return .blue }
        return Color(nsColor: .separatorColor)
    }

    private var strokeLineWidth: CGFloat { hasState ? 4 : 1 }

    private var resolvedFontSize: CGFloat {
        if let fontSize { return fontSize }
        return compact ? 12 : 18
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            previewText
                .lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, compact ? 6 : 14)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 60, alignment: .center)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeLineWidth)
        }
    }

    @ViewBuilder
    private var previewText: some View {
        let displayText = style.text.isEmpty
            ? L10n.tr("subdub.watermark.text.placeholder")
            : style.text
        Text(displayText)
            .font(.custom(style.font.fileURL.path, size: resolvedFontSize))
            .foregroundStyle(textColor)
            .shadow(
                color: style.outlineEnabled ? Color.black.opacity(0.95) : .clear,
                radius: max(style.outlineScale * 200, 0.6),
                x: 0, y: 0
            )
            .shadow(
                color: style.shadowEnabled ? Color.black.opacity(0.55) : .clear,
                radius: 0.5,
                x: max(style.shadowOffsetScale * 50, 0.5),
                y: max(style.shadowOffsetScale * 50, 0.5)
            )
    }

    private var textColor: Color {
        Color(
            red: style.color.red,
            green: style.color.green,
            blue: style.color.blue,
            opacity: style.color.opacity
        )
    }
}

private struct WatermarkTextStyleAddCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Color(nsColor: .windowBackgroundColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(WatermarkThumbnailButtonStyle())
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WatermarkThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct VideoDubbingPanel: View {
    @ObservedObject var viewModel: VideoDubbingViewModel
    let onImportVideo: () -> Void
    let onImportDroppedProviders: ([NSItemProvider]) -> Void
    let onRemoveVideo: () -> Void

    private let dropTypes = [
        UTType.fileURL.identifier,
        UTType.movie.identifier,
        UTType.mpeg4Movie.identifier,
        UTType.quickTimeMovie.identifier
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.hasSource {
                HStack(alignment: .top, spacing: 14) {
                    dubbingControls
                    videoPreview
                }
                dubbingTimeline
            } else {
                dropZone(
                    icon: "film",
                    text: L10n.tr("subdub.action.drop_video"),
                    action: onImportVideo
                )
                .onDrop(of: dropTypes, isTargeted: nil) { providers in
                    onImportDroppedProviders(providers)
                    return true
                }
            }

            statusText(viewModel.statusMessage)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var dubbingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Label(
                    viewModel.sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video"),
                    systemImage: "mic.and.signal.meter"
                )
                .lineLimit(1)
                Spacer(minLength: 0)
                iconButton(
                    systemName: "arrow.triangle.2.circlepath",
                    help: L10n.tr("subdub.action.reselect_video"),
                    action: onImportVideo,
                    isDisabled: viewModel.state.isBusy
                )
                iconButton(
                    systemName: "xmark.circle",
                    help: L10n.tr("subdub.action.remove_video"),
                    action: onRemoveVideo,
                    isDisabled: viewModel.state.isBusy
                )
            }

            dubbingActions
            selectionControls
        }
        .frame(
            width: subDubConfigurationContentWidth,
            height: dubbingConfigurationContentHeight,
            alignment: .bottomLeading
        )
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var dubbingActions: some View {
        HStack(spacing: 8) {
            iconButton(
                systemName: "mic",
                help: L10n.tr("subdub.action.prepare"),
                action: viewModel.prepareDubbing,
                isDisabled: viewModel.state.isBusy
            )

            if viewModel.state == .ready || viewModel.state == .failed ||
                viewModel.state == .finished || viewModel.state == .succeeded {
                iconButton(
                    systemName: "record.circle",
                    help: viewModel.selectedDubbingRange == nil
                        ? L10n.tr("subdub.action.start_recording")
                        : L10n.tr("subdub.action.replace_selection"),
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
    }

    private var videoPreview: some View {
        let previewSize = subDubVideoPreviewSize(for: viewModel.sourceVideoSize)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(viewModel.sourceURL?.lastPathComponent ?? "", systemImage: "film")
                    .lineLimit(1)
                Spacer()
                Text(viewModel.playbackPositionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            SubDubPlayerView(player: viewModel.player)
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button(L10n.tr("subdub.action.remove_video")) {
                        onRemoveVideo()
                    }
                    Button(L10n.tr("subdub.action.reselect_video")) {
                        onImportVideo()
                    }
                }

            HStack(spacing: 8) {
                iconButton(
                    systemName: viewModel.player.timeControlStatus == .playing ? "pause.fill" : "play.fill",
                    help: viewModel.player.timeControlStatus == .playing
                        ? L10n.tr("subdub.action.pause")
                        : L10n.tr("subdub.action.play"),
                    action: viewModel.togglePlayback,
                    isDisabled: !viewModel.isPlayerReady || viewModel.state == .recording || viewModel.state == .paused
                )
                Slider(
                    value: Binding(
                        get: { viewModel.playbackPosition },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(viewModel.sourceDuration, 0.1)
                )
                .disabled(!viewModel.isPlayerReady || viewModel.state == .recording || viewModel.state == .paused)
            }
        }
        .frame(width: 520, alignment: .topLeading)
    }

    private var dubbingConfigurationContentHeight: CGFloat {
        subDubVideoPreviewSize(for: viewModel.sourceVideoSize).height + 47
    }

    private var dubbingTimeline: some View {
        ZStack(alignment: .topLeading) {
            SubDubWaveformView(
                duration: viewModel.sourceDuration,
                position: viewModel.playbackPosition,
                sourceWaveformSamples: viewModel.sourceWaveformSamples,
                dubbingWaveformSamples: viewModel.waveformSamples,
                liveWaveformSamples: viewModel.liveWaveformSamples,
                selection: viewModel.selectedDubbingRange,
                onSelectionChanged: viewModel.setSelectedDubbingRange
            )
            .frame(height: 72)
            .padding(.top, 22)

            SubDubTimelineRuler(
                duration: viewModel.sourceDuration
            )
            .frame(height: 22)

            SubDubTimelinePlayhead(
                duration: viewModel.sourceDuration,
                position: viewModel.playbackPosition
            )
            .allowsHitTesting(false)
        }
        .frame(height: 94)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.09, green: 0.10, blue: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("subdub.video.selection.label"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("00:00", text: $viewModel.selectionStartText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onSubmit { viewModel.updateSelectionFromInputs() }

            Text(L10n.tr("subdub.video.selection.to"))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("00:00", text: $viewModel.selectionEndText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onSubmit { viewModel.updateSelectionFromInputs() }

            if viewModel.selectedDubbingRange != nil {
                Text(viewModel.selectionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.clearSelectedDubbingRange()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help(L10n.tr("subdub.video.selection.clear"))
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SubtitleBurnPanel: View {
    @ObservedObject var viewModel: SubtitleBurnViewModel
    let onImportVideo: () -> Void
    let onImportDroppedProviders: ([NSItemProvider]) -> Void
    let onRemoveVideo: () -> Void

    private let dropTypes = [
        UTType.fileURL.identifier,
        UTType.movie.identifier,
        UTType.plainText.identifier
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                subtitleEditor
                videoPreview
            }

            if viewModel.hasSource {
                SubtitleBurnTimelineView(
                    duration: viewModel.sourceDuration,
                    position: viewModel.playbackPosition,
                    sourceSamples: viewModel.sourceWaveformSamples,
                    cues: viewModel.cues,
                    selectedCueID: viewModel.selectedCueID,
                    onSeek: viewModel.seek
                )
            }

            statusText(viewModel.statusMessage)
        }
        .padding(16)
        .background(cardBackground)
        .onDrop(of: dropTypes, isTargeted: nil) { providers in
            onImportDroppedProviders(providers)
            return true
        }
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Label(
                    L10n.tr("subdub.subtitle_burn.editor"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.subheadline)
                .lineLimit(1)
                Spacer()
                compactIconButton(
                    systemName: "plus",
                    help: L10n.tr("subdub.action.add_subtitle"),
                    action: viewModel.addCue,
                    isDisabled: !viewModel.hasSource || viewModel.state.isBusy
                )
                compactIconButton(
                    systemName: "arrow.down.doc",
                    help: L10n.tr("subdub.action.import_timeline_json"),
                    action: viewModel.importTimelineJSONByPanel,
                    isDisabled: !viewModel.hasSource || viewModel.state.isBusy
                )
                compactIconButton(
                    systemName: "arrow.up.doc",
                    help: L10n.tr("subdub.action.export_timeline_json"),
                    action: viewModel.exportTimelineJSONByPanel,
                    isDisabled: !viewModel.hasSource || viewModel.cues.isEmpty || viewModel.state.isBusy
                )
                previewPositionMenu
                subtitleStyleMenu
                subtitleThemeColorPicker
            }

            if viewModel.cues.isEmpty {
                Text(L10n.tr("subdub.subtitle_burn.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.cues) { cue in
                            SubtitleCueEditorRow(
                                cue: cue,
                                isSelected: cue.id == viewModel.selectedCueID,
                                onSelect: { viewModel.selectCue(cue.id) },
                                onTimeChanged: { start, end in
                                    viewModel.updateCueTime(
                                        id: cue.id,
                                        startText: start,
                                        endText: end
                                    )
                                },
                                onTextChanged: { text in
                                    viewModel.updateCueText(id: cue.id, text: text)
                                },
                                onDelete: { viewModel.removeCue(cue.id) }
                            )
                        }
                    }
                    .padding(4)
                }
            }
        }
        .frame(width: subDubConfigurationContentWidth, height: subtitleEditorHeight, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var subtitleStyleMenu: some View {
        Menu {
            ForEach(SubtitleStylePreset.allCases) { style in
                Button {
                    viewModel.updateSubtitleStyle(style)
                } label: {
                    HStack {
                        Text(L10n.tr(style.titleKey))
                        if style == viewModel.subtitleStyle {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help(L10n.tr("subdub.subtitle_style.label"))
        .disabled(!viewModel.hasSource || viewModel.state.isBusy)
        .opacity(!viewModel.hasSource || viewModel.state.isBusy ? 0.38 : 1)
    }

    @State private var isThemeColorPopoverPresented = false

    private var subtitleThemeColorPicker: some View {
        let color = Color(
            red: viewModel.subtitleThemeColor.red,
            green: viewModel.subtitleThemeColor.green,
            blue: viewModel.subtitleThemeColor.blue,
            opacity: viewModel.subtitleThemeColor.opacity
        )
        return Button {
            isThemeColorPopoverPresented = true
        } label: {
            ZStack {
                // Background grid for transparency preview.
                Image(systemName: "circle.grid.cross.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("subdub.subtitle_style.theme_color"))
        .disabled(!viewModel.hasSource || viewModel.state.isBusy)
        .opacity(!viewModel.hasSource || viewModel.state.isBusy ? 0.38 : 1)
        .popover(isPresented: $isThemeColorPopoverPresented, arrowEdge: .bottom) {
            ColorPicker(
                "",
                selection: Binding(
                    get: { color },
                    set: { newColor in
                        guard let resolved = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                        viewModel.updateSubtitleThemeColor(
                            SubtitleThemeColor(
                                red: Double(resolved.redComponent),
                                green: Double(resolved.greenComponent),
                                blue: Double(resolved.blueComponent),
                                opacity: Double(resolved.alphaComponent)
                            )
                        )
                    }
                ),
                supportsOpacity: true
            )
            .labelsHidden()
            .padding(12)
            .frame(width: 240)
        }
    }

    private var previewPositionMenu: some View {
        Menu {
            ForEach(SubtitlePreviewPosition.allCases) { position in
                Button {
                    viewModel.updatePreviewPosition(position)
                } label: {
                    HStack {
                        Text(L10n.tr(position.titleKey))
                        if position == viewModel.previewPosition {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "eye")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help(L10n.tr("subdub.subtitle_preview.label"))
        .disabled(!viewModel.hasSource || viewModel.state.isBusy)
        .opacity(!viewModel.hasSource || viewModel.state.isBusy ? 0.38 : 1)
    }

    private var subtitleEditorHeight: CGFloat {
        guard viewModel.hasSource else { return 320 }
        // Match the preview header, video surface, and action row on the right.
        return videoPreviewSize.height + 48
    }

    private var videoPreview: some View {
        let previewSize = videoPreviewSize

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    viewModel.sourceURL?.lastPathComponent ?? L10n.tr("subdub.empty.no_video"),
                    systemImage: "film"
                )
                .lineLimit(1)
                Spacer()
                Text("\(formatSubtitleTime(viewModel.playbackPosition)) / \(formatSubtitleTime(viewModel.sourceDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if viewModel.hasSource {
                GeometryReader { proxy in
                    let contentRect = videoContentRect(in: proxy.size)

                    ZStack {
                        SubDubPlayerView(player: viewModel.player)

                        if let cue = viewModel.activeCue,
                           viewModel.previewPosition != .hidden {
                            let style = viewModel.subtitleStyle
                            let fontSize = style.previewFontSize(forVideoHeight: contentRect.height)
                            let horizontalPadding = max(8, fontSize * 0.65)
                            let verticalPadding = max(4, fontSize * 0.25)
                            let bottomMargin = max(6, contentRect.height * style.marginScale)
                            let overlayAlignment: Alignment = viewModel.previewPosition == .center ? .center : .bottom
                            Text(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.custom(style.fontName, size: fontSize))
                                .fontWeight(style.isBold ? .bold : .medium)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(subtitleThemeColor)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: min(max(contentRect.width - 32, 1), 360))
                                .padding(.horizontal, horizontalPadding)
                                .padding(.vertical, verticalPadding)
                                .background(
                                    style.usesBackground
                                        ? Color.black.opacity(style.backgroundOpacity)
                                        : Color.clear
                                )
                                .shadow(
                                    color: style == .outline ? .black : .clear,
                                    radius: style == .outline ? 1.5 : 0,
                                    x: style == .outline ? 1 : 0,
                                    y: style == .outline ? 1 : 0
                                )
                                .padding(.bottom, viewModel.previewPosition == .center ? 0 : bottomMargin)
                                .frame(
                                    width: max(contentRect.width, 1),
                                    height: max(contentRect.height, 1),
                                    alignment: overlayAlignment
                                )
                                .position(x: contentRect.midX, y: contentRect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contextMenu {
                        Button(L10n.tr("subdub.action.remove_video")) {
                            onRemoveVideo()
                        }
                        Button(L10n.tr("subdub.action.reselect_video")) {
                            onImportVideo()
                        }
                }
            } else {
                dropZone(
                    icon: "film",
                    text: L10n.tr("subdub.action.drop_video"),
                    action: onImportVideo
                )
                .frame(minWidth: 420, minHeight: 250)
            }

            HStack(spacing: 8) {
                iconButton(
                    systemName: viewModel.player.timeControlStatus == .playing ? "pause.fill" : "play.fill",
                    help: viewModel.player.timeControlStatus == .playing
                        ? L10n.tr("subdub.action.pause")
                        : L10n.tr("subdub.action.play"),
                    action: viewModel.togglePlayback,
                    isDisabled: !viewModel.isPlayerReady
                )
                labeledAction(
                    icon: "film",
                    title: L10n.tr("subdub.action.import_video"),
                    action: onImportVideo
                )
                labeledAction(
                    icon: "captions.bubble",
                    title: L10n.tr("subdub.action.import_subtitle"),
                    action: viewModel.importSubtitleByPanel,
                    isDisabled: !viewModel.hasSource || viewModel.state.isBusy
                )
                labeledAction(
                    icon: "wand.and.stars",
                    title: L10n.tr("subdub.action.generate_subtitles"),
                    action: viewModel.generateSubtitles,
                    isDisabled: !viewModel.hasSource || viewModel.state.isBusy
                )
                if viewModel.state.isBusy {
                    iconButton(
                        systemName: "xmark",
                        help: L10n.tr("subdub.action.cancel"),
                        action: viewModel.cancelCurrentTask
                    )
                } else {
                    labeledActionWithBadge(
                        systemName: "captions.bubble",
                        title: L10n.tr("subdub.action.burn_export"),
                        help: L10n.tr("subdub.action.burn_export"),
                        action: viewModel.burnSubtitles,
                        badge: L10n.tr("subscription.membership.vip"),
                        isDisabled: !viewModel.canBurn
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 520, alignment: .topLeading)
    }

    private var subtitleThemeColor: Color {
        let color = viewModel.subtitleThemeColor
        return Color(
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.opacity
        )
    }

    private var videoPreviewSize: CGSize {
        subDubVideoPreviewSize(for: viewModel.sourceVideoSize)
    }

    private func labeledAction(
        icon: String,
        title: String,
        action: @escaping () -> Void,
        isDisabled: Bool = false
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }

    private func labeledActionWithBadge(
        systemName: String,
        title: String,
        help: String,
        action: @escaping () -> Void,
        badge: String,
        isDisabled: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16))
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.bordered)
        .help(help)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }

    private func videoContentRect(in containerSize: CGSize) -> CGRect {
        let size = viewModel.sourceVideoSize
        guard size.width > 0, size.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(
            containerSize.width / size.width,
            containerSize.height / size.height
        )
        let contentSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
        return CGRect(
            x: (containerSize.width - contentSize.width) / 2,
            y: (containerSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

private struct AudioReplacementPanel: View {
    @ObservedObject var viewModel: AudioReplacementViewModel
    let onImportVideo: () -> Void
    let onImportDroppedProviders: ([NSItemProvider]) -> Void
    let onRemoveVideo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.hasSource {
                HStack(alignment: .top, spacing: 14) {
                    subtitleEditor
                    videoPreview
                }
                SubtitleBurnTimelineView(
                    duration: viewModel.sourceDuration,
                    position: viewModel.playbackPosition,
                    sourceSamples: viewModel.sourceWaveformSamples,
                    cues: viewModel.cues,
                    selectedCueID: viewModel.selectedCueID,
                    overlaySamples: viewModel.overlayWaveformSamples,
                    overlayDuration: viewModel.overlayWaveformDuration,
                    onSeek: viewModel.seek
                )
            } else {
                emptyState
            }
            statusText(viewModel.statusMessage)
        }
        .padding(16)
        .background(cardBackground)
        .onDrop(of: [
            UTType.fileURL.identifier,
            UTType.movie.identifier,
            UTType.mpeg4Movie.identifier,
            UTType.quickTimeMovie.identifier
        ], isTargeted: nil) { providers in
            onImportDroppedProviders(providers)
            return true
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.tr("subdub.audio_replacement.title"),
                systemImage: "waveform.badge.plus"
            )
            .font(.headline)
            Text(L10n.tr("subdub.audio_replacement.placeholder"))
                .font(.callout)
                .foregroundStyle(.secondary)
            dropZone(
                icon: "film",
                text: L10n.tr("subdub.action.drop_video"),
                action: onImportVideo
            )
            .onDrop(of: [
                UTType.fileURL.identifier,
                UTType.movie.identifier,
                UTType.mpeg4Movie.identifier,
                UTType.quickTimeMovie.identifier
            ], isTargeted: nil) { providers in
                onImportDroppedProviders(providers)
                return true
            }

            HStack(spacing: 8) {
                Button(action: viewModel.importVoiceByPanel) {
                    Label(
                        L10n.tr("subdub.action.import_audio"),
                        systemImage: "waveform.badge.plus"
                    )
                }
                .buttonStyle(.bordered)
                .help(L10n.tr("subdub.audio_replacement.import_hint"))

                Text(L10n.tr("subdub.audio_replacement.import_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    L10n.tr("subdub.subtitle_burn.editor"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.headline)
                Spacer()
                iconButton(
                    systemName: "trash",
                    help: L10n.tr("subdub.action.clear_replacement_audio"),
                    action: viewModel.clearReplacementAudio,
                    isDisabled: !(viewModel.hasReplacementAudio || viewModel.hasImportedAudio) || viewModel.state.isBusy
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.cues) { cue in
                        VStack(alignment: .leading, spacing: 4) {
                            cueEditorRow(for: cue)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(cueStatusColor(viewModel.cueStatuses[cue.id] ?? .pending))
                                    .frame(width: 6, height: 6)
                                Text(viewModel.cueStatusText(for: cue.id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                iconButton(
                                    systemName: "arrow.clockwise",
                                    help: L10n.tr("subdub.action.regenerate_replacement_audio"),
                                    action: { viewModel.regenerateCue(cue.id) },
                                    isDisabled: viewModel.state.isBusy
                                )
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(4)
            }
        }
        .frame(
            width: subDubConfigurationContentWidth,
            height: audioReplacementEditorHeight,
            alignment: .topLeading
        )
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var videoPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(viewModel.sourceName, systemImage: "film")
                    .lineLimit(1)
                Spacer()
                Text(viewModel.playbackPositionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            SubDubPlayerView(player: viewModel.player)
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button(L10n.tr("subdub.action.remove_video")) {
                        onRemoveVideo()
                    }
                    Button(L10n.tr("subdub.action.reselect_video"), action: onImportVideo)
                }

            HStack(spacing: 8) {
                iconButton(
                    systemName: viewModel.player.timeControlStatus == .playing ? "pause.fill" : "play.fill",
                    help: viewModel.player.timeControlStatus == .playing
                        ? L10n.tr("subdub.action.pause")
                        : L10n.tr("subdub.action.play"),
                    action: viewModel.togglePlayback,
                    isDisabled: !viewModel.isPlayerReady
                )
                iconButton(
                    systemName: "stop.fill",
                    help: L10n.tr("subdub.action.stop_recording"),
                    action: viewModel.stopPlayback,
                    isDisabled: !viewModel.isPlayerReady
                )
                audioPreviewControl
                Spacer()
            }

            HStack(alignment: .center, spacing: 8) {
                Picker(L10n.tr("subdub.audio_replacement.language"), selection: Binding(
                    get: { viewModel.languageMode },
                    set: { viewModel.updateLanguageMode($0) }
                )) {
                    ForEach(AudioReplacementLanguageMode.allCases) { mode in
                        Text(L10n.tr(mode.titleKey)).tag(mode)
                    }
                }
                .frame(width: 150)
                Picker(L10n.tr("subdub.audio_replacement.voice"), selection: Binding(
                    get: { viewModel.selectedVoiceIdentifier },
                    set: { viewModel.updateVoiceIdentifier($0) }
                )) {
                    ForEach(viewModel.voiceOptions) { voice in
                        Text(voice.title).tag(voice.id)
                    }
                }
                .frame(width: 220, alignment: .leading)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(L10n.tr("subdub.audio_replacement.rate"))
                    .font(.caption)
                Slider(value: Binding(
                    get: { viewModel.rate },
                    set: { viewModel.updateRate($0) }
                ), in: 0.5...2.0, step: 0.05)
                Text("\(viewModel.rate, specifier: "%.2fx")")
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 8) {
                if viewModel.state.isBusy {
                    iconButton(
                        systemName: "xmark",
                        help: L10n.tr("subdub.action.cancel"),
                        action: viewModel.cancelCurrentTask
                    )
                } else {
                    labeledActionWithBadge(
                        systemName: "waveform.and.mic",
                        title: L10n.tr("subdub.action.generate_replacement_audio"),
                        help: L10n.tr("subdub.action.generate_replacement_audio"),
                        action: viewModel.generateAllAudio,
                        badge: L10n.tr("subscription.membership.vip"),
                        isDisabled: !viewModel.hasCues
                    )
                    labeledActionWithBadge(
                        systemName: "square.and.arrow.down",
                        title: L10n.tr("subdub.action.export_replacement_video"),
                        help: L10n.tr("subdub.action.export_replacement_video"),
                        action: viewModel.exportReplacementVideo,
                        badge: L10n.tr("subscription.membership.vip"),
                        isDisabled: !viewModel.canExport
                    )
                    labeledActionWithBadge(
                        systemName: "waveform.badge.arrow.down",
                        title: L10n.tr("subdub.action.export_audio_replacement"),
                        help: L10n.tr("subdub.action.export_audio_replacement"),
                        action: viewModel.exportAudioReplacement,
                        badge: L10n.tr("subscription.membership.vip"),
                        isDisabled: !viewModel.canAudioReplaceExport
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 520, alignment: .topLeading)
    }

    private var previewSize: CGSize {
        subDubVideoPreviewSize(for: viewModel.sourceVideoSize)
    }

    private var audioReplacementEditorHeight: CGFloat {
        // Keep the left editor card visually aligned with the full preview column.
        previewSize.height + 150
    }

    private var audioPreviewControl: some View {
        HStack(spacing: 2) {
            audioModeButton(.original)
            if viewModel.hasReplacementAudio {
                audioModeButton(.replacement)
            }
            Button(action: viewModel.handleImportedAudioButton) {
                Label(
                    L10n.tr("subdub.action.import_replacement_audio"),
                    systemImage: "waveform.badge.plus"
                )
                .font(.caption)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.previewMode == .imported ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                viewModel.previewMode == .imported
                    ? Color.accentColor
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help(L10n.tr("subdub.action.import_replacement_audio"))
            .disabled(viewModel.state.isBusy || !viewModel.hasSource)

            if let importedAudioURL = viewModel.importedAudioURL {
                Divider()
                    .frame(height: 18)
                Text(importedAudioURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 130, alignment: .leading)
                Button(action: viewModel.removeImportedAudio) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("subdub.action.remove_imported_audio"))
                .disabled(viewModel.state.isBusy)
            }
        }
        .padding(3)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .onDrop(
            of: [UTType.audio.identifier, UTType.fileURL.identifier],
            isTargeted: nil,
            perform: { providers in
                viewModel.importDroppedVoiceProviders(providers)
                return true
            }
        )
    }

    private func audioModeButton(_ mode: AudioPreviewMode) -> some View {
        Button {
            viewModel.setPreviewMode(mode)
        } label: {
            Text(L10n.tr(mode.titleKey))
                .font(.headline)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.previewMode == mode ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(
            viewModel.previewMode == mode
                ? Color.accentColor
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .disabled(viewModel.state.isBusy || !viewModel.hasSource)
    }

    private func cueStatusColor(_ status: AudioReplacementCueStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .generating: return .orange
        case .generated: return .green
        case .failed: return .red
        }
    }

    private func cueEditorRow(for cue: SubtitleTimelineCue) -> some View {
        SubtitleCueEditorRow(
            cue: cue,
            isSelected: cue.id == viewModel.selectedCueID,
            onSelect: { viewModel.selectCue(cue.id) },
            onTimeChanged: { start, end in
                viewModel.updateCueTime(id: cue.id, startText: start, endText: end)
            },
            onTextChanged: { text in
                viewModel.updateCueText(id: cue.id, text: text)
            },
            onDelete: { viewModel.removeCue(cue.id) }
        )
    }

    private func labeledActionWithBadge(
        systemName: String,
        title: String,
        help: String,
        action: @escaping () -> Void,
        badge: String,
        isDisabled: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))
                Text(title)
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16))
                    .clipShape(Capsule())
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .help(help)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }
}

private struct SubtitleCueEditorRow: View {
    let cue: SubtitleTimelineCue
    let isSelected: Bool
    let onSelect: () -> Void
    let onTimeChanged: (String, String) -> Void
    let onTextChanged: (String) -> Void
    let onDelete: () -> Void

    @State private var startText: String
    @State private var endText: String
    @State private var textDraft: String

    init(
        cue: SubtitleTimelineCue,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onTimeChanged: @escaping (String, String) -> Void,
        onTextChanged: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.cue = cue
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onTimeChanged = onTimeChanged
        self.onTextChanged = onTextChanged
        self.onDelete = onDelete
        _startText = State(initialValue: formatSubtitleTime(cue.startTime))
        _endText = State(initialValue: formatSubtitleTime(cue.endTime))
        _textDraft = State(initialValue: cue.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                TextField("00:00.000", text: $startText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .onSubmit { onTimeChanged(startText, endText) }
                Text(L10n.tr("subdub.subtitle_burn.to"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("00:00.000", text: $endText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .onSubmit { onTimeChanged(startText, endText) }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("subdub.action.remove_subtitle"))
            }

            TextEditor(text: $textDraft)
                .font(.caption)
                .foregroundStyle(
                    isDefaultText
                        ? Color.secondary.opacity(0.55)
                        : Color.primary
                )
                .frame(minHeight: 44, maxHeight: 64)
                .padding(3)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .simultaneousGesture(
                    TapGesture().onEnded {
                        clearDefaultTextIfNeeded()
                    }
                )
                .onChange(of: textDraft) { _, value in
                    onTextChanged(value)
                }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var isDefaultText: Bool {
        textDraft == L10n.tr("subdub.subtitle_burn.default_text")
    }

    private func clearDefaultTextIfNeeded() {
        guard isDefaultText else { return }
        textDraft = ""
        onTextChanged("")
    }
}

private struct SubtitleBurnTimelineView: View {
    let duration: Double
    let position: Double
    let sourceSamples: [Double]
    let cues: [SubtitleTimelineCue]
    let selectedCueID: UUID?
    let overlaySamples: [Double]
    let overlayDuration: Double
    let onSeek: ((Double) -> Void)?

    init(
        duration: Double,
        position: Double,
        sourceSamples: [Double],
        cues: [SubtitleTimelineCue],
        selectedCueID: UUID?,
        overlaySamples: [Double] = [],
        overlayDuration: Double = 0,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.duration = duration
        self.position = position
        self.sourceSamples = sourceSamples
        self.cues = cues
        self.selectedCueID = selectedCueID
        self.overlaySamples = overlaySamples
        self.overlayDuration = overlayDuration
        self.onSeek = onSeek
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                SubtitleBurnWaveformCanvas(
                    duration: duration,
                    sourceSamples: sourceSamples,
                    cues: cues,
                    selectedCueID: selectedCueID,
                    overlaySamples: overlaySamples,
                    overlayDuration: overlayDuration
                )
                .frame(height: 72)
                .padding(.top, 22)

                SubDubTimelineRuler(duration: duration)
                    .frame(height: 22)

                SubDubTimelinePlayhead(duration: duration, position: position)
                    .allowsHitTesting(false)
            }
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(onSeek != nil)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let onSeek, duration > 0 else { return }
                                    let progress = min(
                                        max(value.location.x / max(proxy.size.width, 1), 0),
                                        1
                                    )
                                    onSeek(progress * duration)
                                }
                        )
                }
            }
        }
        .frame(height: 94)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.09, green: 0.10, blue: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

}

private struct SubtitleBurnWaveformCanvas: View {
    let duration: Double
    let sourceSamples: [Double]
    let cues: [SubtitleTimelineCue]
    let selectedCueID: UUID?
    let overlaySamples: [Double]
    let overlayDuration: Double

    var body: some View {
        Canvas { context, size in
            let barCount = max(32, Int(size.width / 6))
            let baselineY = size.height / 2

            for cue in cues {
                let start = CGFloat(min(max(cue.startTime / max(duration, 0.001), 0), 1)) * size.width
                let end = CGFloat(min(max(cue.endTime / max(duration, 0.001), 0), 1)) * size.width
                let rect = CGRect(x: start, y: 0, width: max(end - start, 1), height: size.height)
                let color = cue.id == selectedCueID ? Color.accentColor.opacity(0.28) : Color.accentColor.opacity(0.12)
                context.fill(Path(rect), with: .color(color))
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 8, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width - 8, y: baselineY))
            context.stroke(
                baseline,
                with: .color(Color.secondary.opacity(0.42)),
                style: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [1, 3])
            )

            if !sourceSamples.isEmpty {
                for index in 0..<barCount {
                    let fraction = Double(index) / Double(max(barCount - 1, 1))
                    let start = min(
                        sourceSamples.count - 1,
                        Int(Double(index) / Double(barCount) * Double(sourceSamples.count))
                    )
                    let end = min(
                        sourceSamples.count,
                        max(start + 1, Int(Double(index + 1) / Double(barCount) * Double(sourceSamples.count)))
                    )
                    let value = sourceSamples[start..<end].max() ?? 0
                    guard value > 0.02 else { continue }
                    let height = min(size.height * 0.64, size.height * (0.04 + value * 0.60))
                    let rect = CGRect(
                        x: CGFloat(fraction) * size.width,
                        y: (size.height - height) / 2,
                        width: 2,
                        height: max(height, 2)
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(Color.secondary.opacity(0.58))
                    )
                }
            }

            guard !overlaySamples.isEmpty, overlayDuration > 0, duration > 0 else { return }
            let visibleFraction = min(max(overlayDuration / duration, 0), 1)
            let overlayBarCount = max(1, Int(Double(barCount) * visibleFraction))
            for index in 0..<overlayBarCount {
                let sampleFraction = Double(index) / Double(max(overlayBarCount - 1, 1))
                let timelineFraction = sampleFraction * visibleFraction
                let start = min(
                    overlaySamples.count - 1,
                    Int(sampleFraction * Double(overlaySamples.count))
                )
                let end = min(
                    overlaySamples.count,
                    max(start + 1, Int((sampleFraction + 1 / Double(max(overlayBarCount, 1))) * Double(overlaySamples.count)))
                )
                let value = overlaySamples[start..<end].max() ?? 0
                guard value > 0.02 else { continue }
                let height = min(size.height * 0.92, size.height * (0.04 + value * 0.86))
                let rect = CGRect(
                    x: CGFloat(timelineFraction) * size.width,
                    y: (size.height - height) / 2,
                    width: 2,
                    height: max(height, 2)
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(Color.accentColor.opacity(0.9))
                )
            }
        }
        .background(Color.clear)
    }
}

private func formatSubtitleTime(_ seconds: Double) -> String {
    let totalMilliseconds = max(0, Int((seconds * 1_000).rounded()))
    let milliseconds = totalMilliseconds % 1_000
    let totalSeconds = totalMilliseconds / 1_000
    let secondsPart = totalSeconds % 60
    let minutes = totalSeconds / 60
    return String(format: "%02d:%02d.%03d", minutes, secondsPart, milliseconds)
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

private struct WatermarkVideoSurface: View {
    @ObservedObject var viewModel: WatermarkRemovalViewModel
    @State private var dragStartRect: CGRect?
    @State private var activeRegionID: UUID?
    @State private var activeHandle: VideoCropHandle?
    @State private var activeLayer: WatermarkReplacementLayer?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let fitRect = VideoCropGeometry.aspectFitRect(
                contentSize: viewModel.sourceVideoSize,
                boundingSize: proxy.size
            )
            ZStack {
                if let previewImage = viewModel.previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: bounds.width, height: bounds.height)
                        .background(Color.black)
                } else {
                    SubDubPlayerView(player: viewModel.player)
                        .frame(width: bounds.width, height: bounds.height)
                        .background(Color.black)
                }

                if viewModel.previewImage == nil {
                    ForEach(viewModel.regions) { region in
                        watermarkRegionOverlay(
                            region: region,
                            fitRect: fitRect
                        )
                        watermarkReplacementOverlays(
                            region: region,
                            fitRect: fitRect
                        )
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .background(Color.black)
    }

    private func watermarkRegionOverlay(
        region: WatermarkRegion,
        fitRect: CGRect
    ) -> some View {
        let normalized = VideoCropGeometry.clampNormalizedRect(region.rectNormalized.cgRect)
        let frame = CGRect(
            x: fitRect.minX + fitRect.width * normalized.minX,
            y: fitRect.minY + fitRect.height * normalized.minY,
            width: fitRect.width * normalized.width,
            height: fitRect.height * normalized.height
        )
        let isSelected = region.id == viewModel.selectedRegionID

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(isSelected ? 0.15 : 0.08))
                .frame(width: frame.width, height: frame.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.orange : Color.red.opacity(0.8), lineWidth: isSelected ? 2 : 1.5)
                }
                .overlay(alignment: .topLeading) {
                    Text(L10n.f("subdub.watermark.region_item", regionIndex(region.id)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .contentShape(Rectangle())
                .position(x: frame.midX, y: frame.midY)
                .gesture(dragGesture(region: region, frame: frame, fitRect: fitRect))

            if isSelected {
                ForEach(watermarkHandlePoints(frame), id: \.0) { _, point in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.orange, lineWidth: 1))
                        .position(point)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { viewModel.selectRegion(region.id) }
    }

    @ViewBuilder
    private func watermarkReplacementOverlays(
        region: WatermarkRegion,
        fitRect: CGRect
    ) -> some View {
        if let image = region.imageReplacement {
            watermarkImageOverlay(region: region, replacement: image, fitRect: fitRect)
        }
        if let text = region.textReplacement, text.isEnabled {
            watermarkTextOverlay(region: region, replacement: text, fitRect: fitRect)
        }
    }

    private func watermarkImageOverlay(
        region: WatermarkRegion,
        replacement: WatermarkImageReplacement,
        fitRect: CGRect
    ) -> some View {
        let frame = displayFrame(for: replacement.rectNormalized, fitRect: fitRect)
        return replacementLayerOverlay(
            region: region,
            layer: .image,
            frame: frame,
            fitRect: fitRect,
            stroke: .cyan,
            label: L10n.tr("subdub.watermark.layer.png"),
            content: AnyView(
                Image(nsImage: NSImage(contentsOf: replacement.assetURL) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
            )
        )
    }

    private func watermarkTextOverlay(
        region: WatermarkRegion,
        replacement: WatermarkTextReplacement,
        fitRect: CGRect
    ) -> some View {
        let frame = displayFrame(for: replacement.rectNormalized, fitRect: fitRect)
        let color = Color(
            red: replacement.color.red,
            green: replacement.color.green,
            blue: replacement.color.blue,
            opacity: replacement.color.opacity
        )
        return replacementLayerOverlay(
            region: region,
            layer: .text,
            frame: frame,
            fitRect: fitRect,
            stroke: .purple,
            label: L10n.tr("subdub.watermark.layer.text"),
            content: AnyView(
                Text(replacement.text)
                    .font(.custom(previewFontName(for: replacement.font), size: max(9, frame.height)))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.2)
                    .frame(width: frame.width, height: frame.height, alignment: .leading)
            )
        )
    }

    private func replacementLayerOverlay(
        region: WatermarkRegion,
        layer: WatermarkReplacementLayer,
        frame: CGRect,
        fitRect: CGRect,
        stroke: Color,
        label: String,
        content: AnyView
    ) -> some View {
        let selected = region.id == viewModel.selectedRegionID
        return ZStack {
            content
                .overlay {
                    Rectangle()
                        .stroke(stroke.opacity(selected ? 1 : 0.78), lineWidth: selected ? 2 : 1.25)
                }
                .overlay(alignment: .topLeading) {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(stroke.opacity(0.85))
                }
                .contentShape(Rectangle())
                .position(x: frame.midX, y: frame.midY)
                .gesture(replacementDragGesture(
                    region: region,
                    layer: layer,
                    frame: frame,
                    fitRect: fitRect
                ))

            if selected {
                ForEach(watermarkHandlePoints(frame), id: \.0) { _, point in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(stroke, lineWidth: 1))
                        .position(point)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { viewModel.selectRegion(region.id) }
    }

    private func dragGesture(
        region: WatermarkRegion,
        frame: CGRect,
        fitRect: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeRegionID == nil && activeLayer == nil {
                    activeRegionID = region.id
                    viewModel.selectRegion(region.id)
                    activeHandle = handle(at: value.startLocation, frame: frame)
                        ?? .move
                    dragStartRect = region.rectNormalized.cgRect
                }
                guard activeRegionID == region.id,
                      let dragStartRect,
                      let activeHandle else { return }
                viewModel.updateRegion(
                    id: region.id,
                    startingRect: dragStartRect,
                    handle: activeHandle,
                    translation: value.translation,
                    displaySize: fitRect.size
                )
            }
            .onEnded { _ in
                activeRegionID = nil
                activeHandle = nil
                dragStartRect = nil
            }
    }

    private func replacementDragGesture(
        region: WatermarkRegion,
        layer: WatermarkReplacementLayer,
        frame: CGRect,
        fitRect: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeRegionID == nil {
                    activeRegionID = region.id
                    activeLayer = layer
                    viewModel.selectRegion(region.id)
                    activeHandle = handle(at: value.startLocation, frame: frame) ?? .move
                    dragStartRect = replacementRect(for: region, layer: layer)
                }
                guard activeRegionID == region.id,
                      activeLayer == layer,
                      let dragStartRect,
                      let activeHandle else { return }
                viewModel.updateReplacementLayer(
                    regionID: region.id,
                    layer: layer,
                    startingRect: dragStartRect,
                    handle: activeHandle,
                    translation: value.translation,
                    displaySize: fitRect.size
                )
            }
            .onEnded { _ in
                activeRegionID = nil
                activeLayer = nil
                activeHandle = nil
                dragStartRect = nil
            }
    }

    private func displayFrame(for rect: VideoCropRect, fitRect: CGRect) -> CGRect {
        let normalized = VideoCropGeometry.clampNormalizedRect(rect.cgRect)
        return CGRect(
            x: fitRect.minX + fitRect.width * normalized.minX,
            y: fitRect.minY + fitRect.height * normalized.minY,
            width: fitRect.width * normalized.width,
            height: fitRect.height * normalized.height
        )
    }

    private func replacementRect(for region: WatermarkRegion, layer: WatermarkReplacementLayer) -> CGRect? {
        switch layer {
        case .image: return region.imageReplacement?.rectNormalized.cgRect
        case .text: return region.textReplacement?.rectNormalized.cgRect
        }
    }

    private func previewFontName(for font: WatermarkTextFont) -> String {
        switch font {
        case .hiraginoSansGB: return "Hiragino Sans GB"
        case .helvetica: return "Helvetica"
        case .newYork: return "New York"
        }
    }

    private func handle(at location: CGPoint, frame: CGRect) -> VideoCropHandle? {
        let radius: CGFloat = 24
        let points: [(VideoCropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.top, CGPoint(x: frame.midX, y: frame.minY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.minY)),
            (.left, CGPoint(x: frame.minX, y: frame.midY)),
            (.right, CGPoint(x: frame.maxX, y: frame.midY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.bottom, CGPoint(x: frame.midX, y: frame.maxY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY))
        ]
        return points.first { point in
            hypot(location.x - point.1.x, location.y - point.1.y) <= radius
        }?.0
    }

    private func watermarkHandlePoints(_ frame: CGRect) -> [(VideoCropHandle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: frame.minX, y: frame.minY)),
            (.top, CGPoint(x: frame.midX, y: frame.minY)),
            (.topRight, CGPoint(x: frame.maxX, y: frame.minY)),
            (.left, CGPoint(x: frame.minX, y: frame.midY)),
            (.right, CGPoint(x: frame.maxX, y: frame.midY)),
            (.bottomLeft, CGPoint(x: frame.minX, y: frame.maxY)),
            (.bottom, CGPoint(x: frame.midX, y: frame.maxY)),
            (.bottomRight, CGPoint(x: frame.maxX, y: frame.maxY))
        ]
    }

    private func regionIndex(_ id: UUID) -> Int {
        (viewModel.regions.firstIndex { $0.id == id } ?? 0) + 1
    }
}

private struct SubDubTimelineRuler: View {
    let duration: Double

    private var majorStep: Double {
        let candidates = [5.0, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let target = max(duration / 5, 5)
        return candidates.first(where: { $0 >= target }) ?? 3600
    }

    private var minorStep: Double {
        majorStep <= 60 ? majorStep / 5 : majorStep / 10
    }

    private var tickValues: [Double] {
        guard duration > 0 else { return [0] }
        var values = Array(stride(from: 0, through: duration, by: minorStep))
        if let last = values.last, duration - last > 0.5 {
            values.append(duration)
        }
        return values
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            ZStack(alignment: .topLeading) {
                ForEach(tickValues, id: \.self) { value in
                    let tickProgress = duration > 0 ? value / duration : 0
                    let x = min(max(tickProgress * width, 0), width)
                    let isMajor = isMajorTick(value)

                    Rectangle()
                        .fill(Color.white.opacity(isMajor ? 0.32 : 0.14))
                        .frame(width: isMajor ? 1.5 : 1, height: isMajor ? 10 : 6)
                        .position(x: x, y: isMajor ? 5 : 3)

                    if isMajor {
                        Text(formatRulerTime(value))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .frame(width: 56, alignment: .leading)
                            .position(
                                x: min(max(x + 30, 30), max(width - 26, 30)),
                                y: 6
                            )
                    }
                }

            }
        }
    }

    private func isMajorTick(_ value: Double) -> Bool {
        let remainder = value.truncatingRemainder(dividingBy: majorStep)
        return remainder < 0.01 || majorStep - remainder < 0.01 || abs(value - duration) < 0.01
    }

    private func formatRulerTime(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes % 60, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

private struct SubDubWaveformView: View {
    let duration: Double
    let position: Double
    let sourceWaveformSamples: [Double]
    let dubbingWaveformSamples: [Double]
    let liveWaveformSamples: [Double]
    let selection: VideoDubbingRange?
    let onSelectionChanged: (Double, Double) -> Void

    @State private var dragAnchorTime: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    let barCount = max(32, Int(size.width / 6))
                    let progress = duration > 0
                        ? min(max(position / duration, 0), 1)
                        : 0
                    let sourceColor = Color.secondary.opacity(0.48)
                    let dubbingColor = Color.accentColor.opacity(0.92)
                    let selectionColor = Color.accentColor.opacity(0.12)

                    if let selection, duration > 0 {
                        let startX = CGFloat(min(max(selection.startTime / duration, 0), 1)) * size.width
                        let endX = CGFloat(min(max(selection.endTime / duration, 0), 1)) * size.width
                        let selectionRect = CGRect(
                            x: min(startX, endX),
                            y: 0,
                            width: abs(endX - startX),
                            height: size.height
                        )
                        context.fill(Path(selectionRect), with: .color(selectionColor))
                    }

                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 8, y: size.height / 2))
                    baseline.addLine(to: CGPoint(x: size.width - 8, y: size.height / 2))
                    context.stroke(
                        baseline,
                        with: .color(Color.secondary.opacity(0.42)),
                        style: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [1, 3])
                    )

                    func drawBars(_ samples: [Double], color: Color, opacity: Double = 1) {
                        guard !samples.isEmpty else { return }
                        for index in 0..<barCount {
                            let fraction = Double(index) / Double(max(barCount - 1, 1))
                            let start = min(
                                samples.count - 1,
                                Int(Double(index) / Double(barCount) * Double(samples.count))
                            )
                            let end = min(
                                samples.count,
                                max(start + 1, Int(Double(index + 1) / Double(barCount) * Double(samples.count)))
                            )
                            let value = samples[start..<end].max() ?? 0
                            guard value > 0.02 else { continue }
                            let barHeight = min(size.height * 0.86, size.height * (0.04 + value * 0.82))
                            let x = CGFloat(fraction) * size.width
                            let rect = CGRect(
                                x: x,
                                y: (size.height - barHeight) / 2,
                                width: 2,
                                height: max(2, barHeight)
                            )
                            let barColor = fraction <= progress ? color : color.opacity(0.42 * opacity)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 1),
                                with: .color(barColor.opacity(opacity))
                            )
                        }
                    }

                    drawBars(sourceWaveformSamples, color: sourceColor)
                    drawBars(dubbingWaveformSamples, color: dubbingColor)
                    drawBars(liveWaveformSamples, color: dubbingColor)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                if dragAnchorTime == nil {
                                    dragAnchorTime = time(at: value.startLocation.x, width: proxy.size.width)
                                }
                                guard let dragAnchorTime else { return }
                                let current = time(at: value.location.x, width: proxy.size.width)
                                onSelectionChanged(
                                    min(dragAnchorTime, current),
                                    max(dragAnchorTime, current)
                                )
                            }
                            .onEnded { _ in
                                dragAnchorTime = nil
                            }
                    )
            }
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        let normalized = min(max(x / max(width, 1), 0), 1)
        return normalized * duration
    }
}

private struct SubDubTimelinePlayhead: View {
    let duration: Double
    let position: Double

    var body: some View {
        GeometryReader { proxy in
            let progress = duration > 0
                ? min(max(position / duration, 0), 1)
                : 0
            let lineWidth = 1.5
            let x = lineWidth / 2 + CGFloat(progress) * max(proxy.size.width - lineWidth, 0)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: lineWidth, height: proxy.size.height)
                    .position(x: x, y: proxy.size.height / 2)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.10, blue: 0.11))
                    .frame(width: 10, height: 11)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                    .position(x: x, y: 5.5)
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
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
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

private func compactIconButton(
    systemName: String,
    help: String,
    action: @escaping () -> Void,
    isDisabled: Bool = false
) -> some View {
    Button(action: action) {
        Image(systemName: systemName)
            .frame(width: 26, height: 26)
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
