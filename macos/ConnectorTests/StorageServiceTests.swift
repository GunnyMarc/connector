/// Tests for the encrypted StorageService (site CRUD).
///
/// Mirrors the Python `test_storage.py` — covers list, get, create, update,
/// replace, delete operations over encrypted file storage.

import Foundation
import Testing

@testable import Connector

// MARK: - Helpers

/// Create a temp-backed StorageService and CryptoService.
private func makeTempStorage() -> (StorageService, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConnectorTests_\(UUID().uuidString)")
    let keyURL = tmpDir.appendingPathComponent(".key")
    let sitesURL = tmpDir.appendingPathComponent("sites.enc")

    let crypto = CryptoService(keyURL: keyURL)
    let storage = StorageService(fileURL: sitesURL, crypto: crypto)
    return (storage, tmpDir)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// A pre-built test site with password auth.
private func sampleSite() -> Site {
    Site(
        name: "Test Server",
        hostname: "192.168.1.100",
        port: 22,
        username: "admin",
        authType: .password,
        password: "secret123"
    )
}

/// A pre-built test site with key auth.
private func sampleSiteKey() -> Site {
    Site(
        name: "Key Server",
        hostname: "10.0.0.5",
        port: 2222,
        username: "deploy",
        authType: .key,
        keyPath: "~/.ssh/id_ed25519"
    )
}

// MARK: - List Sites

struct TestListSites {
    @Test("Empty storage returns empty list")
    func listEmpty() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let sites = try storage.listSites()
        #expect(sites.isEmpty)
    }

    @Test("List returns all created sites")
    func listReturnsAll() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site1 = sampleSite()
        let site2 = sampleSiteKey()
        try storage.createSite(site1)
        try storage.createSite(site2)

        let sites = try storage.listSites()
        #expect(sites.count == 2)
    }
}

// MARK: - Get Site

struct TestGetSite {
    @Test("Get existing site by ID")
    func getExisting() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        try storage.createSite(site)

        let fetched = try storage.getSite(id: site.id)
        #expect(fetched != nil)
        #expect(fetched?.name == "Test Server")
        #expect(fetched?.hostname == "192.168.1.100")
    }

    @Test("Get non-existent site returns nil")
    func getNonExistent() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let fetched = try storage.getSite(id: "no-such-id")
        #expect(fetched == nil)
    }
}

// MARK: - Create Site

struct TestCreateSite {
    @Test("Create site persists and returns it")
    func createAndPersist() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        let created = try storage.createSite(site)

        #expect(created.id == site.id)
        #expect(created.name == "Test Server")

        // Verify persistence
        let fetched = try storage.getSite(id: site.id)
        #expect(fetched?.name == "Test Server")
    }

    @Test("Create site with all protocols")
    func createAllProtocols() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        for proto in ConnectionProtocol.allCases {
            let site = Site(
                name: "Proto \(proto.label)",
                hostname: "host.local",
                connectionProtocol: proto
            )
            try storage.createSite(site)
        }

        let sites = try storage.listSites()
        #expect(sites.count == 6)
    }

    @Test("Create site preserves password")
    func createPreservesPassword() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        try storage.createSite(site)

        let fetched = try storage.getSite(id: site.id)
        #expect(fetched?.password == "secret123")
    }

    @Test("Create site preserves key path")
    func createPreservesKeyPath() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSiteKey()
        try storage.createSite(site)

        let fetched = try storage.getSite(id: site.id)
        #expect(fetched?.keyPath == "~/.ssh/id_ed25519")
    }
}

// MARK: - Update Site

struct TestUpdateSite {
    @Test("Update site with closure")
    func updateWithClosure() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        try storage.createSite(site)

        let updated = try storage.updateSite(id: site.id) { s in
            s.name = "Updated Server"
            s.port = 3333
        }

        #expect(updated.name == "Updated Server")
        #expect(updated.port == 3333)
        #expect(updated.id == site.id)  // ID must not change
    }

    @Test("Update non-existent site throws error")
    func updateNonExistent() {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        #expect(throws: ConnectorError.self) {
            _ = try storage.updateSite(id: "no-such-id") { s in
                s.name = "Nope"
            }
        }
    }

    @Test("Update preserves ID even if closure tries to change it")
    func updatePreservesID() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        try storage.createSite(site)

        let updated = try storage.updateSite(id: site.id) { s in
            s.id = "hacked-id"
            s.name = "Modified"
        }

        #expect(updated.id == site.id)
        #expect(updated.name == "Modified")
    }
}

// MARK: - Replace Site

struct TestReplaceSite {
    @Test("Replace site entirely")
    func replaceExisting() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        try storage.createSite(site)

        var replacement = site
        replacement.name = "Replaced Server"
        replacement.hostname = "10.10.10.10"
        replacement.port = 9999

        let result = try storage.replaceSite(replacement)

        #expect(result.name == "Replaced Server")
        #expect(result.hostname == "10.10.10.10")
        #expect(result.port == 9999)
    }

    @Test("Replace non-existent site throws error")
    func replaceNonExistent() {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = Site(id: "missing", name: "Ghost")
        #expect(throws: ConnectorError.self) {
            _ = try storage.replaceSite(site)
        }
    }
}

// MARK: - Delete Site

struct TestDeleteSite {
    @Test("Delete existing site returns true")
    func deleteExisting() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site = sampleSite()
        try storage.createSite(site)

        let deleted = try storage.deleteSite(id: site.id)
        #expect(deleted == true)

        let remaining = try storage.listSites()
        #expect(remaining.isEmpty)
    }

    @Test("Delete non-existent site returns false")
    func deleteNonExistent() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let deleted = try storage.deleteSite(id: "no-such-id")
        #expect(deleted == false)
    }

    @Test("Delete only removes the target site")
    func deleteOnlyTarget() throws {
        let (storage, tmpDir) = makeTempStorage()
        defer { cleanup(tmpDir) }

        let site1 = sampleSite()
        let site2 = sampleSiteKey()
        try storage.createSite(site1)
        try storage.createSite(site2)

        try storage.deleteSite(id: site1.id)

        let remaining = try storage.listSites()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == site2.id)
    }
}
