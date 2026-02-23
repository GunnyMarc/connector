/// Tests for the encrypted SettingsService.
///
/// Mirrors the Python `test_settings_service.py` — covers defaults,
/// persistence, partial updates, folder management, and error recovery.

import Foundation
import Testing

@testable import Connector

// MARK: - Helpers

/// Create a temp-backed SettingsService.
private func makeTempSettings() -> (SettingsService, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConnectorTests_\(UUID().uuidString)")
    let keyURL = tmpDir.appendingPathComponent(".key")
    let settingsURL = tmpDir.appendingPathComponent("settings.enc")

    let crypto = CryptoService(keyURL: keyURL)
    let service = SettingsService(fileURL: settingsURL, crypto: crypto)
    return (service, tmpDir)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Defaults

struct TestSettingsDefaults {
    @Test("Fresh settings return factory defaults")
    func freshDefaults() throws {
        let (svc, tmpDir) = makeTempSettings()
        defer { cleanup(tmpDir) }

        let settings = try svc.getAll()

        #expect(settings.defaultPort == 22)
        #expect(settings.sshTimeout == 10)
        #expect(settings.commandTimeout == 30)
        #expect(settings.defaultUsername == "")
        #expect(settings.defaultAuthType == "password")
        #expect(settings.defaultKeyPath == "~/.ssh/id_rsa")
        #expect(settings.folders.isEmpty)
    }

    @Test("AppSettings.defaults matches Python DEFAULTS")
    func staticDefaults() {
        let d = AppSettings.defaults
        #expect(d.defaultPort == 22)
        #expect(d.sshTimeout == 10)
        #expect(d.commandTimeout == 30)
        #expect(d.defaultUsername == "")
        #expect(d.defaultAuthType == "password")
        #expect(d.defaultKeyPath == "~/.ssh/id_rsa")
        #expect(d.folders.isEmpty)
    }
}

// MARK: - Save and Read

struct TestSettingsSaveRead {
    @Test("Save and read round-trip")
    func saveAndRead() throws {
        let (svc, tmpDir) = makeTempSettings()
        defer { cleanup(tmpDir) }

        var settings = AppSettings.defaults
        settings.defaultPort = 2222
        settings.sshTimeout = 20
        settings.defaultUsername = "deploy"

        try svc.save(settings)

        let loaded = try svc.getAll()
        #expect(loaded.defaultPort == 2222)
        #expect(loaded.sshTimeout == 20)
        #expect(loaded.defaultUsername == "deploy")
        // Unchanged fields keep their values
        #expect(loaded.commandTimeout == 30)
        #expect(loaded.defaultKeyPath == "~/.ssh/id_rsa")
    }

    @Test("Update with transform closure")
    func updateTransform() throws {
        let (svc, tmpDir) = makeTempSettings()
        defer { cleanup(tmpDir) }

        try svc.update { s in
            s.commandTimeout = 60
            s.defaultAuthType = "key"
        }

        let loaded = try svc.getAll()
        #expect(loaded.commandTimeout == 60)
        #expect(loaded.defaultAuthType == "key")
        // Other fields remain default
        #expect(loaded.defaultPort == 22)
    }

    @Test("Multiple saves overwrite correctly")
    func multipleOverwrites() throws {
        let (svc, tmpDir) = makeTempSettings()
        defer { cleanup(tmpDir) }

        try svc.update { s in s.sshTimeout = 5 }
        try svc.update { s in s.sshTimeout = 99 }

        let loaded = try svc.getAll()
        #expect(loaded.sshTimeout == 99)
    }
}

// MARK: - Folder Settings

struct TestSettingsFolders {
    @Test("Save and retrieve folder list")
    func folderList() throws {
        let (svc, tmpDir) = makeTempSettings()
        defer { cleanup(tmpDir) }

        try svc.update { s in
            s.folders = ["AWS", "Azure", "AWS/Production"]
        }

        let loaded = try svc.getAll()
        #expect(loaded.folders == ["AWS", "Azure", "AWS/Production"])
    }

    @Test("Empty folder list persists correctly")
    func emptyFolders() throws {
        let (svc, tmpDir) = makeTempSettings()
        defer { cleanup(tmpDir) }

        // First add folders, then clear them.
        try svc.update { s in s.folders = ["Temp"] }
        try svc.update { s in s.folders = [] }

        let loaded = try svc.getAll()
        #expect(loaded.folders.isEmpty)
    }
}

// MARK: - AppSettings Codable

struct TestAppSettingsCodable {
    @Test("AppSettings encodes with snake_case keys")
    func snakeCaseKeys() throws {
        let settings = AppSettings(
            defaultPort: 2222,
            sshTimeout: 15,
            commandTimeout: 45,
            defaultUsername: "user",
            defaultAuthType: "key",
            defaultKeyPath: "~/.ssh/id_ed25519",
            folders: ["A", "B"]
        )

        let data = try JSONEncoder().encode(settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["default_port"] as? Int == 2222)
        #expect(json["ssh_timeout"] as? Int == 15)
        #expect(json["command_timeout"] as? Int == 45)
        #expect(json["default_username"] as? String == "user")
        #expect(json["default_auth_type"] as? String == "key")
        #expect(json["default_key_path"] as? String == "~/.ssh/id_ed25519")
        #expect((json["folders"] as? [String]) == ["A", "B"])
    }

    @Test("AppSettings decodes with missing keys using defaults")
    func decodeMissingKeys() throws {
        // Partial JSON — only some keys present.
        let json = """
        {
            "default_port": 3333,
            "folders": ["Only"]
        }
        """
        let data = json.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(settings.defaultPort == 3333)
        #expect(settings.folders == ["Only"])
        // Missing keys fall back to defaults
        #expect(settings.sshTimeout == 10)
        #expect(settings.commandTimeout == 30)
        #expect(settings.defaultUsername == "")
        #expect(settings.defaultAuthType == "password")
        #expect(settings.defaultKeyPath == "~/.ssh/id_rsa")
    }
}
