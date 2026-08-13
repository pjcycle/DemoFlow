//
//  AudioImportService.swift
//  DemoFlow
//
//  Created by Codex on 2026/7/7.
//

import Foundation
import UniformTypeIdentifiers

final class AudioImportService {
    private let metadataService: AudioMetadataService

    init(metadataService: AudioMetadataService = AudioMetadataService()) {
        self.metadataService = metadataService
    }

    var supportedTypes: [UTType] {
        AudioFileKind.anyAudio.allowedTypes
    }

    func prepareAudio(from url: URL) async throws -> AudioPreparedAsset {
        guard url.isFileURL else {
            throw AudioImportError.fileNotAccessible
        }
        guard url.isSupportedAudioToolLocalFile else {
            throw AudioImportError.unsupportedType
        }
        // Sandbox apps need a security scope to read user-configured output
        // directories outside the container (e.g. ~/Movies/DemoFlow).
        let isAccessingScope = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessingScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await metadataService.preparedAsset(from: url)
    }
}
