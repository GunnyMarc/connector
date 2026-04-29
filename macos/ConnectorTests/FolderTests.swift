/// Tests for folder management in SiteStore.
///
/// Mirrors the Python `test_folders.py` — covers folder creation, renaming,
/// deletion, subfolder nesting, site-to-folder assignment, folder tree building,
/// import/export, and quick-connect parsing.
///
/// Uses a real (temp-backed) storage stack so the full create→persist→reload
/// cycle is exercised, matching the integration-style Python tests.

import Foundation
import Testing

@testable import Connector

// MARK: - Helpers

/// Create a temp-backed SiteStore with real services.
private func makeTempStore() -> (SiteStore, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConnectorTests_\(UUID().uuidString)")
    let keyURL = tmpDir.appendingPathComponent(".key")
    let sitesURL = tmpDir.appendingPathComponent("sites.enc")
    let settingsURL = tmpDir.appendingPathComponent("settings.enc")

    let crypto = CryptoService(keyURL: keyURL)
    let storage = StorageService(fileURL: sitesURL, crypto: crypto)
    let settings = SettingsService(fileURL: settingsURL, crypto: crypto)
    let terminal = TerminalService(platformInfo: PlatformInfo(
        system: "Darwin",
        systemLabel: "macOS",
        terminal: "Terminal",
        hasSshpass: false,
        hasExpect: true
    ))

    let store = SiteStore(storage: storage, settings: settings, terminal: terminal)
    return (store, tmpDir)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Folder Creation

struct TestFolderCreation {
    @Test("Create a folder")
    func createFolder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        #expect(store.folders.contains("AWS"))
    }

    @Test("Create duplicate folder shows error")
    func duplicateFolder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "AWS")
        #expect(store.errorMessage?.contains("already exists") == true)
    }

    @Test("Create folder with empty name shows error")
    func emptyFolderName() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "")
        #expect(store.errorMessage?.contains("required") == true)
    }

    @Test("Create folder with whitespace-only name shows error")
    func whitespaceFolderName() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "   ")
        #expect(store.errorMessage?.contains("required") == true)
    }

    @Test("Folder name is trimmed")
    func folderNameTrimmed() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "  AWS  ")
        #expect(store.folders.contains("AWS"))
    }

    @Test("Multiple folders maintain order")
    func multipleOrder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")
        store.createFolder(name: "GCP")
        #expect(store.folders == ["AWS", "Azure", "GCP"])
    }
}

// MARK: - Subfolder Creation

struct TestSubfolderCreation {
    @Test("Create subfolder with parent")
    func createSubfolder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")

        #expect(store.folders.contains("AWS"))
        #expect(store.folders.contains("AWS/Production"))
    }

    @Test("Create subfolder auto-creates parent")
    func autoCreateParent() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        // Create "AWS/Production" without creating "AWS" first.
        store.createFolder(name: "AWS/Production")

        #expect(store.folders.contains("AWS"))
        #expect(store.folders.contains("AWS/Production"))
    }

    @Test("Deep nesting works")
    func deepNesting() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "A/B/C/D")
        #expect(store.folders.contains("A"))
        #expect(store.folders.contains("A/B"))
        #expect(store.folders.contains("A/B/C"))
        #expect(store.folders.contains("A/B/C/D"))
    }
}

// MARK: - Folder Rename

struct TestFolderRename {
    @Test("Rename a folder")
    func renameFolder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.renameFolder(oldName: "AWS", newName: "Amazon")

        #expect(!store.folders.contains("AWS"))
        #expect(store.folders.contains("Amazon"))
    }

    @Test("Rename cascades to subfolders")
    func renameCascades() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")
        store.createFolder(name: "Staging", parent: "AWS")

        store.renameFolder(oldName: "AWS", newName: "Amazon")

        #expect(!store.folders.contains("AWS"))
        #expect(!store.folders.contains("AWS/Production"))
        #expect(!store.folders.contains("AWS/Staging"))
        #expect(store.folders.contains("Amazon"))
        #expect(store.folders.contains("Amazon/Production"))
        #expect(store.folders.contains("Amazon/Staging"))
    }

    @Test("Rename updates site folder assignments")
    func renameUpdatesSites() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        let site = Site(name: "Server", hostname: "host", folder: "AWS")
        store.createSite(site)

        store.renameFolder(oldName: "AWS", newName: "Amazon")

        let updated = store.sites.first { $0.id == site.id }
        #expect(updated?.folder == "Amazon")
    }

    @Test("Rename non-existent folder shows error")
    func renameNonExistent() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.renameFolder(oldName: "Ghost", newName: "Phantom")
        #expect(store.errorMessage?.contains("not found") == true)
    }

    @Test("Rename to existing name shows error")
    func renameToExisting() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")
        store.renameFolder(oldName: "AWS", newName: "Azure")
        #expect(store.errorMessage?.contains("already exists") == true)
    }
}

// MARK: - Folder Deletion

struct TestFolderDeletion {
    @Test("Delete a folder")
    func deleteFolder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.deleteFolder(name: "AWS")
        #expect(!store.folders.contains("AWS"))
    }

    @Test("Delete cascades to subfolders")
    func deleteCascades() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")
        store.createFolder(name: "Staging", parent: "AWS")

        store.deleteFolder(name: "AWS")
        #expect(store.folders.isEmpty)
    }

    @Test("Delete moves sites to root")
    func deleteMovesToRoot() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        let site = Site(name: "Server", hostname: "host", folder: "AWS")
        store.createSite(site)

        store.deleteFolder(name: "AWS")

        let updated = store.sites.first { $0.id == site.id }
        #expect(updated?.folder == "")
    }
}

// MARK: - Site-Folder Assignment

struct TestSiteFolderAssignment {
    @Test("Move site into folder")
    func moveSiteIntoFolder() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        let site = Site(name: "Server", hostname: "host")
        store.createSite(site)

        store.moveSite(siteID: site.id, toFolder: "AWS")

        let updated = store.sites.first { $0.id == site.id }
        #expect(updated?.folder == "AWS")
    }

    @Test("Move site to root (empty folder)")
    func moveSiteToRoot() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        let site = Site(name: "Server", hostname: "host", folder: "AWS")
        store.createSite(site)

        store.moveSite(siteID: site.id, toFolder: "")

        let updated = store.sites.first { $0.id == site.id }
        #expect(updated?.folder == "")
    }
}

// MARK: - Folder Reorder

struct TestFolderReorder {
    @Test("Reorder folders")
    func reorderFolders() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")
        store.createFolder(name: "GCP")

        store.reorderFolders(["GCP", "AWS", "Azure"])
        #expect(store.folders == ["GCP", "AWS", "Azure"])
    }

    @Test("Reorder with mismatched folders shows error")
    func reorderMismatch() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")

        store.reorderFolders(["AWS", "Azure", "GCP"])
        #expect(store.errorMessage?.contains("same folders") == true)
    }
}

// MARK: - Folder Tree Building

struct TestFolderTree {
    @Test("Flat folders produce root-level nodes")
    func flatFolders() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")

        let tree = store.folderTree
        #expect(tree.count == 2)
        #expect(tree[0].name == "AWS")
        #expect(tree[1].name == "Azure")
    }

    @Test("Nested folders produce child nodes")
    func nestedTree() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")

        let tree = store.folderTree
        #expect(tree.count == 1)  // Only "AWS" at root
        #expect(tree[0].name == "AWS")
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].name == "Production")
    }

    @Test("Sites are assigned to correct folder node")
    func sitesInNodes() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        let site = Site(name: "Server", hostname: "host", folder: "AWS")
        store.createSite(site)

        let tree = store.folderTree
        #expect(tree[0].sites.count == 1)
        #expect(tree[0].sites[0].name == "Server")
    }

    @Test("Root sites are in rootSites, not folder tree")
    func rootSites() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        let rootSite = Site(name: "Unfoldered", hostname: "host")
        let folderedSite = Site(name: "Foldered", hostname: "host", folder: "AWS")
        store.createSite(rootSite)
        store.createSite(folderedSite)

        #expect(store.rootSites.count == 1)
        #expect(store.rootSites[0].name == "Unfoldered")
    }
}

// MARK: - Site CRUD via Store

struct TestSiteStoreCRUD {
    @Test("Create and list sites")
    func createAndList() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        let site = Site(name: "My Server", hostname: "10.0.0.1")
        store.createSite(site)

        #expect(store.sites.count == 1)
        #expect(store.sites[0].name == "My Server")
    }

    @Test("Update a site")
    func updateSite() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        let site = Site(name: "Old Name", hostname: "10.0.0.1")
        store.createSite(site)

        var updated = site
        updated.name = "New Name"
        store.updateSite(updated)

        #expect(store.sites[0].name == "New Name")
    }

    @Test("Delete a site")
    func deleteSite() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        let site = Site(name: "To Delete", hostname: "10.0.0.1")
        store.createSite(site)
        store.deleteSite(id: site.id)

        #expect(store.sites.isEmpty)
    }

    @Test("Duplicate a site")
    func duplicateSite() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        let site = Site(name: "Original", hostname: "10.0.0.1", folder: "AWS")
        store.createSite(site)
        store.createFolder(name: "AWS")
        store.duplicateSite(id: site.id)

        #expect(store.sites.count == 2)
        let copy = store.sites.first { $0.id != site.id }
        #expect(copy?.name == "Original (Copy)")
        #expect(copy?.hostname == "10.0.0.1")
    }

    @Test("Selected site tracks selection")
    func selectedSite() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        let site = Site(name: "Selected", hostname: "host")
        store.createSite(site)

        #expect(store.selectedSiteID == site.id)
        #expect(store.selectedSite?.name == "Selected")
    }

    @Test("Search filters sites")
    func searchFilter() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createSite(Site(name: "Production", hostname: "prod.com"))
        store.createSite(Site(name: "Staging", hostname: "stage.com"))
        store.createSite(Site(name: "Development", hostname: "dev.com"))

        store.searchText = "prod"
        #expect(store.filteredSites.count == 1)
        #expect(store.filteredSites[0].name == "Production")

        store.searchText = ""
        #expect(store.filteredSites.count == 3)
    }
}

// MARK: - Export / Import

struct TestExportImport {
    @Test("Export produces valid JSON with connector_export flag")
    func exportFormat() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createSite(Site(
            name: "Server",
            hostname: "10.0.0.1",
            password: "secret"
        ))

        guard let data = store.exportData(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("Export returned nil or invalid JSON")
            return
        }

        #expect(json["connector_export"] as? Bool == true)
        #expect(json["version"] as? Int == 1)
        #expect(json["exported_at"] != nil)
        #expect((json["folders"] as? [String])?.contains("AWS") == true)

        let sites = json["sites"] as? [[String: Any]]
        #expect(sites?.count == 1)

        // Credentials must be stripped from export.
        let exportedSite = sites?.first
        #expect(exportedSite?["password"] == nil)
        #expect(exportedSite?["key_path"] == nil)
    }

    @Test("Import merges folders and deduplicates sites")
    func importMerge() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        // Pre-existing site
        store.createFolder(name: "AWS")
        store.createSite(Site(
            name: "Existing",
            hostname: "10.0.0.1",
            connectionProtocol: .ssh2
        ))

        // Import payload
        let payload: [String: Any] = [
            "connector_export": true,
            "version": 1,
            "exported_at": "2025-01-01T00:00:00Z",
            "folders": ["AWS", "Azure"],
            "sites": [
                // Duplicate (same name+host+protocol) — should be skipped
                ["name": "Existing", "hostname": "10.0.0.1", "protocol": "ssh2",
                 "port": 22, "username": "", "auth_type": "password",
                 "password": "", "key_path": "", "notes": "",
                 "folder": "AWS", "serial_port": "", "serial_baud": 9600,
                 "sftp_root": ""],
                // New site — should be imported
                ["name": "New Server", "hostname": "10.0.0.2", "protocol": "ssh2",
                 "port": 22, "username": "admin", "auth_type": "password",
                 "password": "", "key_path": "", "notes": "",
                 "folder": "Azure", "serial_port": "", "serial_baud": 9600,
                 "sftp_root": ""],
            ],
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: payload)
        let result = store.importData(jsonData)

        #expect(result.imported == 1)
        #expect(result.skipped == 1)
        #expect(store.folders.contains("Azure"))
        #expect(store.sites.count == 2)
    }

    @Test("Import rejects non-export files")
    func importRejectsInvalid() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        let badData = "{ \"not_an_export\": true }".data(using: .utf8)!
        let result = store.importData(badData)

        #expect(result.imported == 0)
        #expect(result.skipped == 0)
        #expect(store.errorMessage?.contains("not a valid") == true)
    }
}

// MARK: - Move Root Folders (Drag-and-Drop Reorder)

struct TestMoveRootFolders {
    @Test("Move root folder forward")
    func moveForward() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")
        store.createFolder(name: "GCP")

        // Move "AWS" (index 0) to after "GCP" (to index 3)
        store.moveRootFolders(from: IndexSet(integer: 0), to: 3)
        #expect(store.folders == ["Azure", "GCP", "AWS"])
    }

    @Test("Move root folder backward")
    func moveBackward() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")
        store.createFolder(name: "GCP")

        // Move "GCP" (index 2) to index 0
        store.moveRootFolders(from: IndexSet(integer: 2), to: 0)
        #expect(store.folders == ["GCP", "AWS", "Azure"])
    }

    @Test("Move root folder preserves subtree order")
    func preservesSubtree() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")
        store.createFolder(name: "Staging", parent: "AWS")
        store.createFolder(name: "Azure")

        // Flat: ["AWS", "AWS/Production", "AWS/Staging", "Azure"]
        // Root tree: [AWS, Azure]
        // Move "Azure" (root index 1) to index 0
        store.moveRootFolders(from: IndexSet(integer: 1), to: 0)

        // Azure should come first, then AWS with its children
        #expect(store.folders == ["Azure", "AWS", "AWS/Production", "AWS/Staging"])
    }

    @Test("Move to same position is no-op")
    func moveNoop() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Azure")

        let before = store.folders
        store.moveRootFolders(from: IndexSet(integer: 0), to: 0)
        #expect(store.folders == before)
    }
}

// MARK: - Move Child Folders (Drag-and-Drop Reorder)

struct TestMoveChildFolders {
    @Test("Reorder direct children of a parent")
    func reorderChildren() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")
        store.createFolder(name: "Staging", parent: "AWS")
        store.createFolder(name: "Development", parent: "AWS")

        // Children: [Production, Staging, Development]
        // Move "Development" (child index 2) to index 0
        store.moveChildFolders(parent: "AWS", from: IndexSet(integer: 2), to: 0)

        let awsChildren = store.folders.filter {
            $0.hasPrefix("AWS/") && !$0.dropFirst(4).contains("/")
        }
        #expect(awsChildren == ["AWS/Development", "AWS/Production", "AWS/Staging"])
    }

    @Test("Reorder children preserves grandchildren")
    func preservesGrandchildren() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")
        store.createFolder(name: "US-East", parent: "AWS/Production")
        store.createFolder(name: "US-West", parent: "AWS/Production")
        store.createFolder(name: "Staging", parent: "AWS")

        // Flat: ["AWS", "AWS/Production", "AWS/Production/US-East",
        //        "AWS/Production/US-West", "AWS/Staging"]
        // Move "Staging" (child index 1) to index 0
        store.moveChildFolders(parent: "AWS", from: IndexSet(integer: 1), to: 0)

        // Expected: AWS, AWS/Staging, AWS/Production, AWS/Production/US-East, AWS/Production/US-West
        #expect(store.folders == [
            "AWS",
            "AWS/Staging",
            "AWS/Production",
            "AWS/Production/US-East",
            "AWS/Production/US-West",
        ])
    }

    @Test("Reorder children does not affect sibling roots")
    func siblingRootsUnaffected() {
        let (store, tmpDir) = makeTempStore()
        defer { cleanup(tmpDir) }

        store.createFolder(name: "AWS")
        store.createFolder(name: "Production", parent: "AWS")
        store.createFolder(name: "Staging", parent: "AWS")
        store.createFolder(name: "Azure")

        // Move "Staging" (child index 1) to index 0
        store.moveChildFolders(parent: "AWS", from: IndexSet(integer: 1), to: 0)

        // Azure should still be at the end
        #expect(store.folders.last == "Azure")
        #expect(store.folders.contains("Azure"))
    }
}
