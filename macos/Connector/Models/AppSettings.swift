/// Global application settings with sensible defaults.
///
/// Mirrors the Python `SettingsService.DEFAULTS` dictionary. Settings are
/// stored encrypted alongside site data.

import Foundation

/// Global settings for the Connector application.
struct AppSettings: Codable, Sendable {
    var defaultPort: Int
    var sshTimeout: Int
    var commandTimeout: Int
    var defaultUsername: String
    var defaultAuthType: String
    var defaultKeyPath: String
    var folders: [String]

    /// Factory defaults matching the Python app.
    static let defaults = AppSettings(
        defaultPort: 22,
        sshTimeout: 10,
        commandTimeout: 30,
        defaultUsername: "",
        defaultAuthType: "password",
        defaultKeyPath: "~/.ssh/id_rsa",
        folders: []
    )

    enum CodingKeys: String, CodingKey {
        case defaultPort     = "default_port"
        case sshTimeout      = "ssh_timeout"
        case commandTimeout  = "command_timeout"
        case defaultUsername  = "default_username"
        case defaultAuthType = "default_auth_type"
        case defaultKeyPath  = "default_key_path"
        case folders
    }

    /// Decode with fallback to defaults for any missing keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults

        defaultPort     = (try? container.decode(Int.self, forKey: .defaultPort))     ?? d.defaultPort
        sshTimeout      = (try? container.decode(Int.self, forKey: .sshTimeout))      ?? d.sshTimeout
        commandTimeout  = (try? container.decode(Int.self, forKey: .commandTimeout))  ?? d.commandTimeout
        defaultUsername  = (try? container.decode(String.self, forKey: .defaultUsername))  ?? d.defaultUsername
        defaultAuthType = (try? container.decode(String.self, forKey: .defaultAuthType)) ?? d.defaultAuthType
        defaultKeyPath  = (try? container.decode(String.self, forKey: .defaultKeyPath))  ?? d.defaultKeyPath
        folders         = (try? container.decode([String].self, forKey: .folders))     ?? d.folders
    }

    init(
        defaultPort: Int = 22,
        sshTimeout: Int = 10,
        commandTimeout: Int = 30,
        defaultUsername: String = "",
        defaultAuthType: String = "password",
        defaultKeyPath: String = "~/.ssh/id_rsa",
        folders: [String] = []
    ) {
        self.defaultPort = defaultPort
        self.sshTimeout = sshTimeout
        self.commandTimeout = commandTimeout
        self.defaultUsername = defaultUsername
        self.defaultAuthType = defaultAuthType
        self.defaultKeyPath = defaultKeyPath
        self.folders = folders
    }
}
