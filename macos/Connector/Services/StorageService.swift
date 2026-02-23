/// Encrypted file storage for site connection entries.
///
/// Sites are serialised to JSON, encrypted via `CryptoService`, and
/// written to a single `.enc` text file. Mirrors the Python `SiteStorage` class.

import Foundation

/// CRUD operations backed by an encrypted text file.
final class StorageService: Sendable {
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

    // MARK: - Internal Helpers

    /// Decrypt and parse the storage file, returning all sites.
    private func readAll() throws -> [Site] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return [] }

        let ciphertext = try String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ciphertext.isEmpty else { return [] }

        let plaintext = try crypto.decrypt(ciphertext)
        guard let data = plaintext.data(using: .utf8) else { return [] }
        return try decoder.decode([Site].self, from: data)
    }

    /// Serialise, encrypt, and persist all sites.
    private func writeAll(_ sites: [Site]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(sites)
        guard let plaintext = String(data: data, encoding: .utf8) else {
            throw ConnectorError.storageFailed("Failed to encode sites as UTF-8")
        }

        let ciphertext = try crypto.encrypt(plaintext)
        try ciphertext.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Public CRUD

    /// Return every stored site.
    func listSites() throws -> [Site] {
        try readAll()
    }

    /// Look up a single site by its UUID.
    func getSite(id: String) throws -> Site? {
        try readAll().first { $0.id == id }
    }

    /// Append a new site and persist.
    @discardableResult
    func createSite(_ site: Site) throws -> Site {
        var sites = try readAll()
        sites.append(site)
        try writeAll(sites)
        return site
    }

    /// Merge updates into the matching site and persist.
    @discardableResult
    func updateSite(id: String, updates: (inout Site) -> Void) throws -> Site {
        var sites = try readAll()
        guard let idx = sites.firstIndex(where: { $0.id == id }) else {
            throw ConnectorError.siteNotFound(id)
        }
        updates(&sites[idx])
        sites[idx].id = id  // Prevent ID overwrite
        try writeAll(sites)
        return sites[idx]
    }

    /// Replace a site entirely (by matching ID) and persist.
    @discardableResult
    func replaceSite(_ site: Site) throws -> Site {
        var sites = try readAll()
        guard let idx = sites.firstIndex(where: { $0.id == site.id }) else {
            throw ConnectorError.siteNotFound(site.id)
        }
        sites[idx] = site
        try writeAll(sites)
        return site
    }

    /// Remove the site with the given ID. Returns true on success.
    @discardableResult
    func deleteSite(id: String) throws -> Bool {
        var sites = try readAll()
        let before = sites.count
        sites.removeAll { $0.id == id }
        guard sites.count < before else { return false }
        try writeAll(sites)
        return true
    }
}
