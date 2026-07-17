import Foundation
import Security

final class SubDubKeychainService {
    private let service: String
    private let account = "openai-api-key"

    init(service: String = Bundle.main.bundleIdentifier.map { "\($0).subdub" } ?? "demoflow.subdub") {
        self.service = service
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.isEmpty ? nil : value
    }

    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
}

final class OpenAITTSService: SubDubTTSService {
    private let keychain: SubDubKeychainService
    private let session: URLSession

    init(keychain: SubDubKeychainService = SubDubKeychainService(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    var hasAPIKey: Bool { keychain.loadAPIKey() != nil }

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        keychain.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func synthesize(request: SubDubTTSRequest) async throws -> URL {
        guard let apiKey = keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw SubDubError.apiKeyMissing
        }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubDubError.emptyText
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": request.voice,
            "input": request.text,
            "response_format": "mp3",
            "speed": min(max(request.speed, 0.25), 4.0)
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SubDubError.networkFailed(L10n.tr("subdub.error.invalid_response"))
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let serverMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw SubDubError.serviceFailed(sanitizedServerMessage(serverMessage))
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DemoFlow", isDirectory: true)
                .appendingPathComponent("tmp", isDirectory: true)
                .appendingPathComponent("SubDub", isDirectory: true)
                .appendingPathComponent("TTS", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let outputURL = directory.appendingPathComponent("voiceover_\(UUID().uuidString).mp3")
            try data.write(to: outputURL, options: .atomic)
            return outputURL
        } catch let error as SubDubError {
            throw error
        } catch {
            throw SubDubError.networkFailed(error.localizedDescription)
        }
    }

    private func sanitizedServerMessage(_ message: String) -> String {
        message.replacingOccurrences(of: "Bearer", with: "[redacted]", options: .caseInsensitive)
    }
}
