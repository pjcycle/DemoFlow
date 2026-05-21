//
//  VideoCuttingImportPanelService.swift
//  DemoFlow
//
//  Created by PJ Lee on 2026/5/17.
//

#if os(macOS)
import AppKit
#endif
import Foundation
import UniformTypeIdentifiers

struct VideoCuttingImportPanelService {
    private let allowedContentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]

    @MainActor
    func pickSourceURL() -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = allowedContentTypes
        panel.directoryURL = try? DemoFlowOutputDirectoryPolicy.prepareVideoCuttingImportDirectory()

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        DemoFlowOutputDirectoryPolicy.rememberVideoCuttingImportDirectory(from: url)
        return url
        #else
        return nil
        #endif
    }
}
