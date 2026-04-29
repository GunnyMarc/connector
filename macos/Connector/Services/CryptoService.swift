/// AES-GCM encryption service for site and settings storage.
///
/// Uses CryptoKit's AES.GCM (256-bit key) instead of the Python app's Fernet
/// (AES-128-CBC). The encrypted format is NOT cross-compatible with the Python
/// version — each platform manages its own key and encrypted files.

import CryptoKit
import Foundation

/// Encrypt and decrypt data using AES-256-GCM via CryptoKit.
final class CryptoService: Sendable {
    private let keyURL: URL

    /// Lazily loaded symmetric key, stored on disk.
    private let _key: SymmetricKey

    init(keyURL: URL) {
        self.keyURL = keyURL
        self._key = Self._loadOrCreateKey(at: keyURL)
    }

    // MARK: - Key Management

    /// Load the key from disk or generate a new one.
    private static func _loadOrCreateKey(at url: URL) -> SymmetricKey {
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                return SymmetricKey(data: data)
            } catch {
                // If the key file is corrupted, generate a new one.
                // This will make existing encrypted data unreadable.
            }
        }

        // Generate a new 256-bit key.
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        do {
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try keyData.write(to: url, options: .atomic)

            // Restrict permissions to owner-only (chmod 600).
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // Key will work for this session but won't persist.
        }

        return key
    }

    // MARK: - Public API

    /// Encrypt a plaintext string, returning a base64-encoded ciphertext.
    func encrypt(_ plaintext: String) throws -> String {
        guard let data = plaintext.data(using: .utf8) else {
            throw ConnectorError.encryptionFailed("Invalid UTF-8 input")
        }

        do {
            let sealed = try AES.GCM.seal(data, using: _key)
            guard let combined = sealed.combined else {
                throw ConnectorError.encryptionFailed("Failed to combine sealed box")
            }
            return combined.base64EncodedString()
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt a base64-encoded ciphertext, returning the plaintext string.
    func decrypt(_ ciphertext: String) throws -> String {
        guard let data = Data(base64Encoded: ciphertext) else {
            throw ConnectorError.decryptionFailed("Invalid base64 input")
        }

        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let decrypted = try AES.GCM.open(box, using: _key)
            guard let plaintext = String(data: decrypted, encoding: .utf8) else {
                throw ConnectorError.decryptionFailed("Decrypted data is not valid UTF-8")
            }
            return plaintext
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.decryptionFailed(error.localizedDescription)
        }
    }
}
