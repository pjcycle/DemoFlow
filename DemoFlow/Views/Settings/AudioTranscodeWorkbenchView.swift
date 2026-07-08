//
//  AudioTranscodeWorkbenchView.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import SwiftUI
import UniformTypeIdentifiers

struct AudioTranscodeWorkbenchView: View {
    @ObservedObject var viewModel: AudioTranscodeViewModel

    private let compactBreakpoint: CGFloat = 1120

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < compactBreakpoint

            workbenchCard(isCompact: isCompact)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $viewModel.isDropTargeted, perform: viewModel.handleDrop)
        }
        .frame(minHeight: 760)
    }

    private func workbenchCard(isCompact: Bool) -> some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                toolbarRow
                outputSettingsRow

                importDropZone
                    .frame(height: viewModel.jobs.isEmpty ? 156 : 92)

                if !viewModel.jobs.isEmpty {
                    contentSection(isCompact: isCompact)
                }
            }
        }
    }

    private var toolbarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text(L10n.tr("audio.tool.tab.transcode"))
                    .font(.headline)

                Button(L10n.tr("audio.import.action.choose_files")) {
                    viewModel.presentImporter()
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.tr("audio.transcode.action.convert_selected")) {
                    viewModel.convertSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canConvertSelected)

                Button(L10n.tr("audio.transcode.action.convert_all")) {
                    viewModel.convertAll()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canConvertAll)

                Button(L10n.tr("audio.transcode.action.stop")) {
                    viewModel.stopConversion()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canStop)

                Button(L10n.tr("audio.transcode.action.reset")) {
                    viewModel.resetJobs()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canReset)
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var outputSettingsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 10) {
                formatMenu
                badge(text: L10n.tr(viewModel.draft.outputFormat.titleKey), color: .orange)
                statusPill(viewModel.statusMessage)

                if viewModel.shouldShowQualityPreset {
                    settingLabel(L10n.tr("audio.transcode.output.quality"))

                    ForEach(viewModel.qualityPresets) { preset in
                        qualityRadioOption(
                            title: L10n.tr(preset.titleKey),
                            selected: viewModel.draft.qualityPreset == preset
                        ) {
                            viewModel.setQualityPreset(preset)
                        }
                    }
                }

                if let job = viewModel.selectedJob {
                    badge(text: L10n.tr(job.status.titleKey), color: statusColor(for: job.status))
                }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func contentSection(isCompact: Bool) -> some View {
        Group {
            if isCompact {
                VStack(spacing: 12) {
                    jobsSection
                    currentJobSection
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    jobsSection
                        .frame(width: 320, alignment: .topLeading)

                    currentJobSection
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var jobsSection: some View {
        sectionPanel(title: L10n.tr("audio.transcode.jobs.title"), icon: "list.bullet.rectangle") {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.jobs) { job in
                        Button {
                            viewModel.selectJob(id: job.id)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(statusColor(for: job.status))
                                    .frame(width: 9, height: 9)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(job.preparedAsset.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Text(job.preparedAsset.sourceFormatHint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Text(L10n.tr(job.status.titleKey))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                if viewModel.draft.selectedJobID == job.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.18))
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(viewModel.draft.selectedJobID == job.id ? Color.orange.opacity(0.08) : Color.black.opacity(0.03))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 260)
        }
    }

    private var currentJobSection: some View {
        sectionPanel(title: L10n.tr("audio.transcode.current.title"), icon: "waveform") {
            if let job = viewModel.selectedJob {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.04))
                            .frame(width: 52, height: 52)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.18))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.preparedAsset.displayName)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Text(job.preparedAsset.sourceFormatHint)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        badge(text: L10n.tr(job.status.titleKey), color: statusColor(for: job.status))
                    }

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 130), spacing: 10)
                    ], spacing: 10) {
                        infoTile(title: L10n.tr("audio.transcode.meta.duration"), value: job.preparedAsset.durationText)
                        infoTile(title: L10n.tr("audio.transcode.meta.channels"), value: job.preparedAsset.channelCountText)
                        infoTile(title: L10n.tr("audio.transcode.meta.sample_rate"), value: job.preparedAsset.sampleRateText)
                        infoTile(title: L10n.tr("audio.transcode.meta.target"), value: L10n.tr(viewModel.draft.outputFormat.titleKey))
                        infoTile(title: L10n.tr("audio.transcode.meta.file_size"), value: job.preparedAsset.byteCountText)
                    }

                    if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let result = job.result {
                        Text(L10n.f("audio.transcode.result.summary", result.outputURL.lastPathComponent, result.byteCountText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                emptyState(L10n.tr("audio.transcode.empty.current"))
            }
        }
    }

    private var importDropZone: some View {
        Button {
            viewModel.presentImporter()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.18))

                Text(L10n.tr("audio.transcode.import.drop"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(L10n.tr("audio.transcode.import.supported"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(viewModel.isDropTargeted ? Color.orange.opacity(0.12) : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        viewModel.isDropTargeted ? Color.orange.opacity(0.40) : Color.black.opacity(0.10),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 6])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var formatMenu: some View {
        Menu {
            ForEach(viewModel.outputFormats) { format in
                Button(L10n.tr(format.titleKey)) {
                    viewModel.setOutputFormat(format)
                }
            }
        } label: {
            HStack(spacing: 8) {
                settingLabel(L10n.tr("audio.transcode.output.format"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
    private func sectionPanel<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.89, green: 0.40, blue: 0.19))

                Text(title)
                    .font(.headline)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func qualityRadioOption(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(selected ? Color(red: 0.88, green: 0.42, blue: 0.18) : .secondary)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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
    private func infoTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    @ViewBuilder
    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func statusColor(for status: AudioTranscodeJobStatus) -> Color {
        switch status {
        case .queued:
            return .gray.opacity(0.6)
        case .converting:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}
