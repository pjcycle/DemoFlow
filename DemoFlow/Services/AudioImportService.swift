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
        return try await metadataService.preparedAsset(from: url)
    }
}
