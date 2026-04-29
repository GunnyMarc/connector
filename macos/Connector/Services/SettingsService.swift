/// Encrypted settings storage for global application options.
///
/// Mirrors the Python `SettingsService` — reads/writes `AppSettings` through
/// the same `CryptoService` used for site data.

import Foundation

/// Read and write global settings backed by an encrypted file.
final class SettingsService: Sendable {
    private let fileURL: URL
    private let crypto: CryptoService
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL, crypto: CryptoService) {
        self.fileURL = fileURL
        self.crypto = crypto

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        self.decoder = JSONDecoder()
    }

    // MARK: - Read

    /// Return the full settings, merged with defaults for any missing keys.
    func getAll() throws -> AppSettings {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return .defaults
        }

        let ciphertext = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ciphertext.isEmpty else { return .defaults }

        let plaintext = try crypto.decrypt(ciphertext)
        guard let data = plaintext.data(using: .utf8) else { return .defaults }

        return try decoder.decode(AppSettings.self, from: data)
    }

    // MARK: - Write

    /// Persist the full settings object.
    func save(_ settings: AppSettings) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(settings)
        guard let plaintext = String(data: data, encoding: .utf8) else {
            throw ConnectorError.storageFailed("Failed to encode settings")
        }

        let ciphertext = try crypto.encrypt(plaintext)
        try ciphertext.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Update specific fields and persist.
    func update(_ transform: (inout AppSettings) -> Void) throws {
        var settings = try getAll()
        transform(&settings)
        try save(settings)
    }
}
