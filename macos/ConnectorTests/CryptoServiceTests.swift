/// Tests for the AES-256-GCM CryptoService.
///
/// Mirrors the Python `test_crypto_service.py` — covers key generation,
/// file permissions, encrypt/decrypt round-trips, and error handling.

import Foundation
import Testing

@testable import Connector

// MARK: - Helpers

/// Create a CryptoService backed by a temp directory.
private func makeTempCrypto() -> (CryptoService, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConnectorTests_\(UUID().uuidString)")
    let keyURL = tmpDir.appendingPathComponent(".key")
    let crypto = CryptoService(keyURL: keyURL)
    return (crypto, tmpDir)
}

/// Clean up a temp directory.
private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Key Management

struct TestCryptoKeyManagement {
    @Test("Key file is created on first use")
    func keyFileCreated() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        // Encrypt something to trigger key creation.
        _ = try crypto.encrypt("trigger")

        let keyURL = tmpDir.appendingPathComponent(".key")
        #expect(FileManager.default.fileExists(atPath: keyURL.path))
    }

    @Test("Key file has restrictive permissions (0600)")
    func keyFilePermissions() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        _ = try crypto.encrypt("trigger")

        let keyURL = tmpDir.appendingPathComponent(".key")
        let attrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("Same key is reused across instances")
    func keyPersistence() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectorTests_\(UUID().uuidString)")
        let keyURL = tmpDir.appendingPathComponent(".key")
        defer { cleanup(tmpDir) }

        let crypto1 = CryptoService(keyURL: keyURL)
        let ciphertext = try crypto1.encrypt("persistent data")

        // Create a second instance pointing at the same key file.
        let crypto2 = CryptoService(keyURL: keyURL)
        let plaintext = try crypto2.decrypt(ciphertext)

        #expect(plaintext == "persistent data")
    }

    @Test("Different keys cannot decrypt each other's data")
    func differentKeysCannotDecrypt() throws {
        let (crypto1, tmpDir1) = makeTempCrypto()
        let (crypto2, tmpDir2) = makeTempCrypto()
        defer { cleanup(tmpDir1); cleanup(tmpDir2) }

        let ciphertext = try crypto1.encrypt("secret")

        // Decrypting with a different key should fail.
        #expect(throws: ConnectorError.self) {
            _ = try crypto2.decrypt(ciphertext)
        }
    }
}

// MARK: - Encrypt / Decrypt

struct TestCryptoEncryptDecrypt {
    @Test("Encrypt and decrypt round-trip")
    func roundTrip() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        let plaintext = "Hello, Connector!"
        let ciphertext = try crypto.encrypt(plaintext)
        let result = try crypto.decrypt(ciphertext)

        #expect(result == plaintext)
        #expect(ciphertext != plaintext)  // Must be different from plaintext
    }

    @Test("Encrypt produces different ciphertext each time (nonce)")
    func nonceVariation() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        let ct1 = try crypto.encrypt("same input")
        let ct2 = try crypto.encrypt("same input")

        // AES-GCM uses a random nonce, so ciphertexts should differ.
        #expect(ct1 != ct2)
    }

    @Test("Ciphertext is valid base64")
    func ciphertextIsBase64() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        let ciphertext = try crypto.encrypt("test data")
        let decoded = Data(base64Encoded: ciphertext)
        #expect(decoded != nil)
    }

    @Test("Empty string encrypts and decrypts")
    func emptyString() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        let ct = try crypto.encrypt("")
        let pt = try crypto.decrypt(ct)
        #expect(pt == "")
    }

    @Test("Unicode content round-trips")
    func unicodeContent() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        let text = "Passwords: p@$$w0rd! / Emoji: \u{1F512}\u{1F511}"
        let ct = try crypto.encrypt(text)
        let pt = try crypto.decrypt(ct)
        #expect(pt == text)
    }

    @Test("Decrypt with invalid base64 throws decryption error")
    func invalidBase64() {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        #expect(throws: ConnectorError.self) {
            _ = try crypto.decrypt("not-valid-base64!!!")
        }
    }

    @Test("Decrypt with tampered ciphertext throws error")
    func tamperedCiphertext() throws {
        let (crypto, tmpDir) = makeTempCrypto()
        defer { cleanup(tmpDir) }

        let ct = try crypto.encrypt("original data")
        // Tamper: flip a character in the base64 string.
        var chars = Array(ct)
        if chars.count > 10 {
            chars[10] = chars[10] == "A" ? "B" : "A"
        }
        let tampered = String(chars)

        #expect(throws: ConnectorError.self) {
            _ = try crypto.decrypt(tampered)
        }
    }
}
