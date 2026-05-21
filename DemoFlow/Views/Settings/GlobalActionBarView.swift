//
//  GlobalActionBarView.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/4/30.
//

import AppKit
import SwiftUI

struct GlobalActionBarView: View {
    @ObservedObject var appCoordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Button(actionButtonTitle) {
                if appCoordinator.recorderState.isRecording {
                    appCoordinator.stopRecordingAndRestoreMonitoring()
                } else {
                    appCoordinator.startRecordingFromCurrentConfig()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(actionButtonDisabled)

            if let outputURL = appCoordinator.recorder.lastOutputURL {
                Button(L10n.tr("legacy.key_123")) {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 10)

            Label(appCoordinator.statusMessage, systemImage: appCoordinator.recorderState.isRecording ? "record.circle.fill" : "record.circle")
                .font(.footnote)
                .foregroundStyle(appCoordinator.recorderState.isRecording ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var actionButtonTitle: String {
        if appCoordinator.recorderState.isRecording {
            return L10n.tr("legacy.key_15")
        }
        if appCoordinator.isRecordingArmed {
            return L10n.tr("legacy.key_189")
        }
        return L10n.tr("legacy.key_102")
    }

    private var actionButtonDisabled: Bool {
        if appCoordinator.recorderState.isRecording {
            return appCoordinator.recorderState.isBusy
        }
        return appCoordinator.recorderState.isBusy || !appCoordinator.canStartRecording
    }
}
