/// Tests for the Site model, ConnectionProtocol, and AuthType.
///
/// Mirrors the Python `test_site.py` — covers creation, defaults, serialisation
/// round-trips, computed properties, masked password, and protocol/auth enums.

import Foundation
import Testing

@testable import Connector

// MARK: - Site Creation

struct TestSiteCreation {
    @Test("Site has default values")
    func siteDefaults() {
        let site = Site()
        #expect(site.name == "")
        #expect(site.hostname == "")
        #expect(site.port == 22)
        #expect(site.username == "")
        #expect(site.authType == .password)
        #expect(site.password == "")
        #expect(site.keyPath == "")
        #expect(site.notes == "")
        #expect(site.folder == "")
        #expect(site.connectionProtocol == .ssh2)
        #expect(site.serialPort == "")
        #expect(site.serialBaud == 9600)
        #expect(site.sftpRoot == "")
        #expect(site.tunnelEnabled == false)
        #expect(site.tunnelUsername == "")
        #expect(site.tunnelKeyPath == "")
        #expect(site.tunnelSourcePort == 0)
        #expect(site.tunnelDestPort == 0)
        #expect(!site.id.isEmpty)
    }

    @Test("Site with all fields populated")
    func siteWithAllFields() {
        let site = Site(
            id: "test-uuid-123",
            name: "Production Server",
            hostname: "prod.example.com",
            port: 2222,
            username: "admin",
            authType: .key,
            password: "",
            keyPath: "~/.ssh/id_ed25519",
            notes: "Primary production server",
            folder: "AWS",
            connectionProtocol: .ssh2,
            serialPort: "",
            serialBaud: 9600,
            sftpRoot: "/var/www",
            tunnelEnabled: true,
            tunnelUsername: "tunnel_user",
            tunnelKeyPath: "~/.ssh/tunnel_key",
            tunnelSourcePort: 8080,
            tunnelDestPort: 80
        )
        #expect(site.id == "test-uuid-123")
        #expect(site.name == "Production Server")
        #expect(site.hostname == "prod.example.com")
        #expect(site.port == 2222)
        #expect(site.username == "admin")
        #expect(site.authType == .key)
        #expect(site.keyPath == "~/.ssh/id_ed25519")
        #expect(site.notes == "Primary production server")
        #expect(site.folder == "AWS")
        #expect(site.connectionProtocol == .ssh2)
        #expect(site.sftpRoot == "/var/www")
        #expect(site.tunnelEnabled == true)
        #expect(site.tunnelUsername == "tunnel_user")
        #expect(site.tunnelKeyPath == "~/.ssh/tunnel_key")
        #expect(site.tunnelSourcePort == 8080)
        #expect(site.tunnelDestPort == 80)
    }

    @Test("Site generates unique UUIDs")
    func siteUniqueIDs() {
        let site1 = Site(name: "Site A")
        let site2 = Site(name: "Site B")
        #expect(site1.id != site2.id)
    }

    @Test("Site with password auth")
    func sitePasswordAuth() {
        let site = Site(
            name: "Test",
            hostname: "host.local",
            authType: .password,
            password: "secret123"
        )
        #expect(site.authType == .password)
        #expect(site.password == "secret123")
        #expect(site.keyPath == "")
    }

    @Test("Site with key auth")
    func siteKeyAuth() {
        let site = Site(
            name: "Test",
            hostname: "host.local",
            authType: .key,
            keyPath: "~/.ssh/id_rsa"
        )
        #expect(site.authType == .key)
        #expect(site.keyPath == "~/.ssh/id_rsa")
        #expect(site.password == "")
    }

    @Test("Site with serial protocol")
    func siteSerial() {
        let site = Site(
            name: "Router Console",
            connectionProtocol: .serial,
            serialPort: "/dev/ttyUSB0",
            serialBaud: 115200
        )
        #expect(site.connectionProtocol == .serial)
        #expect(site.serialPort == "/dev/ttyUSB0")
        #expect(site.serialBaud == 115200)
    }
}

// MARK: - Codable Round-Trip

struct TestSiteCodable {
    @Test("Site encodes and decodes with snake_case keys")
    func codableRoundTrip() throws {
        let original = Site(
            id: "fixed-id",
            name: "Test Server",
            hostname: "192.168.1.1",
            port: 2222,
            username: "root",
            authType: .key,
            password: "",
            keyPath: "~/.ssh/id_rsa",
            notes: "A test note",
            folder: "Lab",
            connectionProtocol: .ssh1,
            serialPort: "/dev/tty0",
            serialBaud: 115200,
            sftpRoot: "/home",
            tunnelEnabled: true,
            tunnelUsername: "tunneler",
            tunnelKeyPath: "~/.ssh/tunnel_key",
            tunnelSourcePort: 3306,
            tunnelDestPort: 3306
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Site.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.hostname == original.hostname)
        #expect(decoded.port == original.port)
        #expect(decoded.username == original.username)
        #expect(decoded.authType == original.authType)
        #expect(decoded.password == original.password)
        #expect(decoded.keyPath == original.keyPath)
        #expect(decoded.notes == original.notes)
        #expect(decoded.folder == original.folder)
        #expect(decoded.connectionProtocol == original.connectionProtocol)
        #expect(decoded.serialPort == original.serialPort)
        #expect(decoded.serialBaud == original.serialBaud)
        #expect(decoded.sftpRoot == original.sftpRoot)
        #expect(decoded.tunnelEnabled == original.tunnelEnabled)
        #expect(decoded.tunnelUsername == original.tunnelUsername)
        #expect(decoded.tunnelKeyPath == original.tunnelKeyPath)
        #expect(decoded.tunnelSourcePort == original.tunnelSourcePort)
        #expect(decoded.tunnelDestPort == original.tunnelDestPort)
    }

    @Test("Site JSON uses snake_case coding keys")
    func jsonKeysAreSnakeCase() throws {
        let site = Site(
            id: "abc",
            name: "Test",
            hostname: "host",
            authType: .password,
            connectionProtocol: .ssh2,
            tunnelEnabled: true,
            tunnelUsername: "tuser",
            tunnelKeyPath: "~/.ssh/tkey",
            tunnelSourcePort: 5432,
            tunnelDestPort: 5432
        )
        let data = try JSONEncoder().encode(site)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify snake_case keys match Python format
        #expect(json["auth_type"] as? String == "password")
        #expect(json["key_path"] != nil)
        #expect(json["serial_port"] != nil)
        #expect(json["serial_baud"] != nil)
        #expect(json["sftp_root"] != nil)
        // "protocol" key (not "connectionProtocol")
        #expect(json["protocol"] as? String == "ssh2")
        // Tunnel keys use snake_case
        #expect(json["tunnel_enabled"] as? Bool == true)
        #expect(json["tunnel_username"] as? String == "tuser")
        #expect(json["tunnel_key_path"] as? String == "~/.ssh/tkey")
        #expect(json["tunnel_source_port"] as? Int == 5432)
        #expect(json["tunnel_dest_port"] as? Int == 5432)
        // Camel-case keys should NOT exist
        #expect(json["authType"] == nil)
        #expect(json["keyPath"] == nil)
        #expect(json["connectionProtocol"] == nil)
        #expect(json["tunnelEnabled"] == nil)
        #expect(json["tunnelUsername"] == nil)
        #expect(json["tunnelKeyPath"] == nil)
        #expect(json["tunnelSourcePort"] == nil)
        #expect(json["tunnelDestPort"] == nil)
    }

    @Test("Site decodes from Python-compatible JSON")
    func decodeFromPythonJSON() throws {
        let json = """
        {
            "id": "py-uuid",
            "name": "From Python",
            "hostname": "10.0.0.1",
            "port": 22,
            "username": "user",
            "auth_type": "key",
            "password": "",
            "key_path": "~/.ssh/id_ed25519",
            "notes": "",
            "folder": "Imported",
            "protocol": "ssh2",
            "serial_port": "",
            "serial_baud": 9600,
            "sftp_root": ""
        }
        """
        let data = json.data(using: .utf8)!
        let site = try JSONDecoder().decode(Site.self, from: data)

        #expect(site.id == "py-uuid")
        #expect(site.name == "From Python")
        #expect(site.authType == .key)
        #expect(site.keyPath == "~/.ssh/id_ed25519")
        #expect(site.connectionProtocol == .ssh2)
        #expect(site.folder == "Imported")
    }

    @Test("Site decodes legacy JSON without tunnel fields")
    func decodeLegacyWithoutTunnel() throws {
        let json = """
        {
            "id": "legacy-id",
            "name": "Old Server",
            "hostname": "10.0.0.1",
            "port": 22,
            "username": "user",
            "auth_type": "password",
            "password": "secret",
            "key_path": "",
            "notes": "",
            "folder": "",
            "protocol": "ssh2",
            "serial_port": "",
            "serial_baud": 9600,
            "sftp_root": ""
        }
        """
        let data = json.data(using: .utf8)!
        let site = try JSONDecoder().decode(Site.self, from: data)

        #expect(site.id == "legacy-id")
        #expect(site.name == "Old Server")
        // Tunnel fields default gracefully
        #expect(site.tunnelEnabled == false)
        #expect(site.tunnelUsername == "")
        #expect(site.tunnelKeyPath == "")
        #expect(site.tunnelSourcePort == 0)
        #expect(site.tunnelDestPort == 0)
        #expect(site.hasTunnel == false)
    }

    @Test("Site Hashable conformance")
    func siteHashable() {
        let site1 = Site(id: "same-id", name: "Site A")
        let site2 = Site(id: "same-id", name: "Site A")
        let site3 = Site(id: "diff-id", name: "Site A")

        // Same id + same fields -> same hash
        #expect(site1.hashValue == site2.hashValue)
        // Different id -> different hash (most likely)
        var set = Set<Site>()
        set.insert(site1)
        set.insert(site3)
        #expect(set.count == 2)
    }
}

// MARK: - Computed Properties

struct TestSiteProperties {
    @Test("Protocol label returns human-readable string")
    func protocolLabel() {
        #expect(Site(connectionProtocol: .ssh2).protocolLabel == "SSH2")
        #expect(Site(connectionProtocol: .ssh1).protocolLabel == "SSH1")
        #expect(Site(connectionProtocol: .local).protocolLabel == "Local Shell")
        #expect(Site(connectionProtocol: .raw).protocolLabel == "Raw")
        #expect(Site(connectionProtocol: .telnet).protocolLabel == "Telnet")
        #expect(Site(connectionProtocol: .serial).protocolLabel == "Serial")
    }

    @Test("isSSH returns true only for SSH protocols")
    func isSSH() {
        #expect(Site(connectionProtocol: .ssh2).isSSH == true)
        #expect(Site(connectionProtocol: .ssh1).isSSH == true)
        #expect(Site(connectionProtocol: .local).isSSH == false)
        #expect(Site(connectionProtocol: .raw).isSSH == false)
        #expect(Site(connectionProtocol: .telnet).isSSH == false)
        #expect(Site(connectionProtocol: .serial).isSSH == false)
    }

    @Test("isNetwork returns true for network protocols")
    func isNetwork() {
        #expect(Site(connectionProtocol: .ssh2).isNetwork == true)
        #expect(Site(connectionProtocol: .ssh1).isNetwork == true)
        #expect(Site(connectionProtocol: .raw).isNetwork == true)
        #expect(Site(connectionProtocol: .telnet).isNetwork == true)
        #expect(Site(connectionProtocol: .local).isNetwork == false)
        #expect(Site(connectionProtocol: .serial).isNetwork == false)
    }

    @Test("Masked password returns asterisks capped at 8")
    func maskedPassword() {
        #expect(Site(password: "").maskedPassword == "")
        #expect(Site(password: "abc").maskedPassword == "***")
        #expect(Site(password: "12345678").maskedPassword == "********")
        #expect(Site(password: "a very long password").maskedPassword == "********")
    }

    @Test("hasTunnel requires enabled, username, and both ports")
    func hasTunnel() {
        // Fully configured tunnel
        let full = Site(
            hostname: "host.local",
            tunnelEnabled: true,
            tunnelUsername: "tuser",
            tunnelSourcePort: 8080,
            tunnelDestPort: 80
        )
        #expect(full.hasTunnel == true)

        // Disabled tunnel
        let disabled = Site(
            hostname: "host.local",
            tunnelEnabled: false,
            tunnelUsername: "tuser",
            tunnelSourcePort: 8080,
            tunnelDestPort: 80
        )
        #expect(disabled.hasTunnel == false)

        // Missing username
        let noUser = Site(
            hostname: "host.local",
            tunnelEnabled: true,
            tunnelSourcePort: 8080,
            tunnelDestPort: 80
        )
        #expect(noUser.hasTunnel == false)

        // Missing source port
        let noSrc = Site(
            hostname: "host.local",
            tunnelEnabled: true,
            tunnelUsername: "tuser",
            tunnelDestPort: 80
        )
        #expect(noSrc.hasTunnel == false)

        // Missing dest port
        let noDst = Site(
            hostname: "host.local",
            tunnelEnabled: true,
            tunnelUsername: "tuser",
            tunnelSourcePort: 8080
        )
        #expect(noDst.hasTunnel == false)

        // Defaults (no tunnel configured)
        let defaults = Site()
        #expect(defaults.hasTunnel == false)
    }
}

// MARK: - ConnectionProtocol Enum

struct TestConnectionProtocol {
    @Test("All six protocols exist")
    func allCases() {
        let cases = ConnectionProtocol.allCases
        #expect(cases.count == 6)
        #expect(cases.contains(.ssh2))
        #expect(cases.contains(.ssh1))
        #expect(cases.contains(.local))
        #expect(cases.contains(.raw))
        #expect(cases.contains(.telnet))
        #expect(cases.contains(.serial))
    }

    @Test("Protocol raw values match Python identifiers")
    func rawValues() {
        #expect(ConnectionProtocol.ssh2.rawValue == "ssh2")
        #expect(ConnectionProtocol.ssh1.rawValue == "ssh1")
        #expect(ConnectionProtocol.local.rawValue == "local")
        #expect(ConnectionProtocol.raw.rawValue == "raw")
        #expect(ConnectionProtocol.telnet.rawValue == "telnet")
        #expect(ConnectionProtocol.serial.rawValue == "serial")
    }

    @Test("Protocol labels are human-readable")
    func labels() {
        #expect(ConnectionProtocol.ssh2.label == "SSH2")
        #expect(ConnectionProtocol.ssh1.label == "SSH1")
        #expect(ConnectionProtocol.local.label == "Local Shell")
        #expect(ConnectionProtocol.raw.label == "Raw")
        #expect(ConnectionProtocol.telnet.label == "Telnet")
        #expect(ConnectionProtocol.serial.label == "Serial")
    }

    @Test("isSSH computed property")
    func isSSH() {
        #expect(ConnectionProtocol.ssh2.isSSH == true)
        #expect(ConnectionProtocol.ssh1.isSSH == true)
        #expect(ConnectionProtocol.local.isSSH == false)
        #expect(ConnectionProtocol.raw.isSSH == false)
        #expect(ConnectionProtocol.telnet.isSSH == false)
        #expect(ConnectionProtocol.serial.isSSH == false)
    }

    @Test("isNetwork computed property")
    func isNetwork() {
        #expect(ConnectionProtocol.ssh2.isNetwork == true)
        #expect(ConnectionProtocol.ssh1.isNetwork == true)
        #expect(ConnectionProtocol.raw.isNetwork == true)
        #expect(ConnectionProtocol.telnet.isNetwork == true)
        #expect(ConnectionProtocol.local.isNetwork == false)
        #expect(ConnectionProtocol.serial.isNetwork == false)
    }
}

// MARK: - AuthType Enum

struct TestAuthType {
    @Test("AuthType cases and raw values")
    func authTypeCases() {
        #expect(AuthType.allCases.count == 2)
        #expect(AuthType.password.rawValue == "password")
        #expect(AuthType.key.rawValue == "key")
    }

    @Test("AuthType labels")
    func authTypeLabels() {
        #expect(AuthType.password.label == "Password")
        #expect(AuthType.key.label == "SSH Key")
    }
}
