//
//  VideoCuttingImportService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/4.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum VideoCuttingImportError: LocalizedError {
    case unsupportedDropPayload
    case resolveDroppedFileFailed
    case importedFileNotReachable
    case copyImportedFileFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedDropPayload:
            return L10n.tr("legacy.mp4_mov_2")
        case .resolveDroppedFileFailed:
            return L10n.tr("legacy.key_132")
        case .importedFileNotReachable:
            return L10n.tr("legacy.key_53")
        case .copyImportedFileFailed:
            return L10n.tr("legacy.key_50")
        }
    }
}

struct VideoCuttingImportService {
    let allowedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
    private let droppedTypeCandidates: [UTType] = [.fileURL, .movie, .quickTimeMovie, .mpeg4Movie]
    let dropTypeIdentifiers: [String] = [
        UTType.fileURL.identifier,
        UTType.movie.identifier,
        UTType.quickTimeMovie.identifier,
        UTType.mpeg4Movie.identifier
    ]

    func persistImportedVideo(from url: URL) throws -> URL {
        let resolvedURL = normalizeDroppedURL(url)
        guard resolvedURL.isFileURL else {
            throw VideoCuttingImportError.resolveDroppedFileFailed
        }

        let isAccessingSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourcePath = resolvedURL.path
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw VideoCuttingImportError.importedFileNotReachable
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoFlow", isDirectory: true)
            .appendingPathComponent("VideoCuttingImports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let fileExtension = resolvedURL.pathExtension.isEmpty ? "mov" : resolvedURL.pathExtension
        let destination = folder.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: resolvedURL, to: destination)
            return destination
        } catch {
            throw VideoCuttingImportError.copyImportedFileFailed
        }
    }

    func resolveDroppedProviders(_ providers: [NSItemProvider], completion: @escaping (Result<URL, Error>) -> Void) {
        guard let provider = providers.first(where: providerSupportsDropPayload(_:)) else {
            completion(.failure(VideoCuttingImportError.unsupportedDropPayload))
            return
        }

        loadBestURL(from: provider) { result in
            switch result {
            case let .success(url):
                // loadFileRepresentation may hand us a temporary URL that becomes invalid
                // immediately after callback returns; persist it before hopping queues.
                do {
                    let persisted = try persistImportedVideo(from: url)
                    DispatchQueue.main.async {
                        completion(.success(persisted))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            case let .failure(error):
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func isSupportedVideo(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return allowedTypes.contains { type.conforms(to: $0) }
    }

    private func providerSupportsDropPayload(_ provider: NSItemProvider) -> Bool {
        dropTypeIdentifiers.contains(where: { provider.hasItemConformingToTypeIdentifier($0) })
    }

    private func loadBestURL(from provider: NSItemProvider, completion: @escaping (Result<URL, Error>) -> Void) {
        loadFileRepresentation(
            from: provider,
            typeIdentifiers: dropTypeIdentifiers
        ) { result in
            switch result {
            case let .success(url):
                completion(.success(url))
            case .failure:
                loadFallbackItemURL(from: provider, completion: completion)
            }
        }
    }

    private func loadFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifiers: [String],
        index: Int = 0,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard index < typeIdentifiers.count else {
            completion(.failure(VideoCuttingImportError.resolveDroppedFileFailed))
            return
        }

        let typeIdentifier = typeIdentifiers[index]
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            loadFileRepresentation(from: provider, typeIdentifiers: typeIdentifiers, index: index + 1, completion: completion)
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            if let url {
                completion(.success(url))
                return
            }
            self.loadFileRepresentation(from: provider, typeIdentifiers: typeIdentifiers, index: index + 1, completion: completion)
        }
    }

    private func loadFallbackItemURL(from provider: NSItemProvider, completion: @escaping (Result<URL, Error>) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            completion(.failure(VideoCuttingImportError.resolveDroppedFileFailed))
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let url = Self.extractURL(from: item) {
                completion(.success(url))
            } else {
                completion(.failure(VideoCuttingImportError.resolveDroppedFileFailed))
            }
        }
    }

    private func normalizeDroppedURL(_ url: URL) -> URL {
        if url.isFileURL {
            let normalizedFromPath = URL(fileURLWithPath: url.path)
            return normalizedFromPath.standardizedFileURL
        }

        if let decoded = URL(string: url.absoluteString.removingPercentEncoding ?? url.absoluteString), decoded.isFileURL {
            let normalizedFromPath = URL(fileURLWithPath: decoded.path)
            return normalizedFromPath.standardizedFileURL
        }

        return url
    }

    private static func extractURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let text = item as? NSString {
            return URL(string: text as String)
        }
        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return nil
    }
}
