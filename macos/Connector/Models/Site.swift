/// Site connection data model.
///
/// Mirrors the Python `Site` dataclass with 14 fields. Uses `connectionProtocol`
/// in Swift (since `protocol` is a reserved keyword) with a CodingKey mapping
/// to `"protocol"` for JSON compatibility.

import Foundation

// MARK: - ConnectionProtocol

/// Supported connection protocol identifiers.
enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh2   = "ssh2"
    case ssh1   = "ssh1"
    case local  = "local"
    case raw    = "raw"
    case telnet = "telnet"
    case serial = "serial"

    var id: String { rawValue }

    /// Human-readable display label.
    var label: String {
        switch self {
        case .ssh2:   "SSH2"
        case .ssh1:   "SSH1"
        case .local:  "Local Shell"
        case .raw:    "Raw"
        case .telnet: "Telnet"
        case .serial: "Serial"
        }
    }

    /// Whether this protocol uses SSH (v1 or v2).
    var isSSH: Bool { self == .ssh1 || self == .ssh2 }

    /// Whether this protocol requires hostname/port.
    var isNetwork: Bool { [.ssh1, .ssh2, .raw, .telnet].contains(self) }
}

// MARK: - AuthType

/// Authentication method for SSH connections.
enum AuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password = "password"
    case key      = "key"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: "Password"
        case .key:      "SSH Key"
        }
    }
}

// MARK: - Site

/// Represents a remote site connection entry.
///
/// Maps 1:1 with the Python `Site` dataclass. The `connectionProtocol` property
/// is encoded as `"protocol"` in JSON for cross-compatibility with the Python app's
/// export format.
struct Site: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authType: AuthType
    var password: String
    var keyPath: String
    var notes: String
    var folder: String
    var connectionProtocol: ConnectionProtocol
    var serialPort: String
    var serialBaud: Int
    var sftpRoot: String

    /// Create a new site with sensible defaults.
    init(
        id: String = UUID().uuidString,
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authType: AuthType = .password,
        password: String = "",
        keyPath: String = "",
        notes: String = "",
        folder: String = "",
        connectionProtocol: ConnectionProtocol = .ssh2,
        serialPort: String = "",
        serialBaud: Int = 9600,
        sftpRoot: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = authType
        self.password = password
        self.keyPath = keyPath
        self.notes = notes
        self.folder = folder
        self.connectionProtocol = connectionProtocol
        self.serialPort = serialPort
        self.serialBaud = serialBaud
        self.sftpRoot = sftpRoot
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case hostname
        case port
        case username
        case authType     = "auth_type"
        case password
        case keyPath      = "key_path"
        case notes
        case folder
        case connectionProtocol = "protocol"
        case serialPort   = "serial_port"
        case serialBaud   = "serial_baud"
        case sftpRoot     = "sftp_root"
    }

    // MARK: - Computed Properties

    /// Human-readable label for this site's protocol.
    var protocolLabel: String { connectionProtocol.label }

    /// Whether this site uses an SSH protocol.
    var isSSH: Bool { connectionProtocol.isSSH }

    /// Whether this site requires hostname/port fields.
    var isNetwork: Bool { connectionProtocol.isNetwork }

    /// Password replaced with asterisks for safe display.
    var maskedPassword: String {
        guard !password.isEmpty else { return "" }
        return String(repeating: "*", count: min(password.count, 8))
    }
}
