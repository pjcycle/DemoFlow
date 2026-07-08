//
//  VideoCuttingExportService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct VideoCuttingExportService {
    func pickOutputURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = try? DemoFlowOutputDirectoryPolicy.prepareVideoCutsDirectory()
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }
        DemoFlowOutputDirectoryPolicy.rememberVideoCutsDirectory(from: url)
        return url
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func confirmUpscaleExport(sourceSize: CGSize, targetSize: CGSize) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.f(
            "video.cut.export_size.upscale_confirm",
            pixelSizeText(sourceSize)
        )
        alert.informativeText = L10n.f(
            "video.cut.export_size.upscale_target",
            pixelSizeText(targetSize)
        )
        alert.addButton(withTitle: L10n.tr("video.cut.export_size.confirm_continue"))
        alert.addButton(withTitle: L10n.tr("video.cut.export_size.confirm_cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pixelSizeText(_ size: CGSize) -> String {
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        return "\(width)x\(height)"
    }
}
