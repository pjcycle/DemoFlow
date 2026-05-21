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
}
