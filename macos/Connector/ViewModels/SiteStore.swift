/// Central observable store for site and folder management.
///
/// Mirrors the combined functionality of the Python `SiteStorage`, folder
/// routes, and the Flask context processor's sidebar data injection.

import Foundation
import Observation
import SwiftUI

/// Folder separator used in path-based folder names (e.g. "AWS/Production").
private let folderSep = "/"

// MARK: - Folder Tree Node

/// A node in the recursive folder tree for sidebar display.
struct FolderNode: Identifiable, Hashable {
    let id: String          // Full path (used as key)
    let name: String        // Display label (last segment)
    let path: String        // Full path
    var children: [FolderNode]
    var sites: [Site]

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - SiteStore

/// Observable store managing sites, folders, and their persistence.
@Observable
final class SiteStore {
    // MARK: - Published State

    var sites: [Site] = []
    var folders: [String] = []
    var selectedSiteID: String?
    var searchText: String = ""
    var errorMessage: String?

    // MARK: - Dependencies

    private let storage: StorageService
    private let settings: SettingsService
    let terminal: TerminalService

    init(storage: StorageService, settings: SettingsService, terminal: TerminalService) {
        self.storage = storage
        self.settings = settings
        self.terminal = terminal
        reload()
    }

    // MARK: - Computed Properties

    /// The currently selected site.
    var selectedSite: Site? {
        guard let id = selectedSiteID else { return nil }
        return sites.first { $0.id == id }
    }

    /// Sites filtered by search text.
    var filteredSites: [Site] {
        guard !searchText.isEmpty else { return sites }
        let query = searchText.lowercased()
        return sites.filter {
            $0.name.lowercased().contains(query) ||
            $0.hostname.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
    }

    /// Sites not assigned to any known folder (root-level).
    var rootSites: [Site] {
        let folderSet = Set(folders)
        return filteredSites.filter { $0.folder.isEmpty || !folderSet.contains($0.folder) }
    }

    /// Build the recursive folder tree for sidebar display.
    var folderTree: [FolderNode] {
        buildFolderTree(folderPaths: folders, allSites: filteredSites)
    }

    // MARK: - Data Loading

    /// Reload sites and folders from encrypted storage.
    func reload() {
        do {
            sites = try storage.listSites()
            let appSettings = try settings.getAll()
            folders = appSettings.folders
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Site CRUD

    /// Create a new site.
    func createSite(_ site: Site) {
        do {
            try storage.createSite(site)
            reload()
            selectedSiteID = site.id
        } catch {
            errorMessage = "Failed to create site: \(error.localizedDescription)"
        }
    }

    /// Update an existing site.
    func updateSite(_ site: Site) {
        do {
            try storage.replaceSite(site)
            reload()
        } catch {
            errorMessage = "Failed to update site: \(error.localizedDescription)"
        }
    }

    /// Delete a site by ID.
    func deleteSite(id: String) {
        do {
            try storage.deleteSite(id: id)
            if selectedSiteID == id {
                selectedSiteID = nil
            }
            reload()
        } catch {
            errorMessage = "Failed to delete site: \(error.localizedDescription)"
        }
    }

    /// Duplicate a site with "(Copy)" appended to the name.
    func duplicateSite(id: String) {
        guard let original = sites.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID().uuidString
        copy.name = "\(original.name) (Copy)"
        createSite(copy)
    }

    // MARK: - Folder CRUD

    /// Create a new folder (with optional parent).
    func createFolder(name: String, parent: String = "") {
        let fullPath: String
        if parent.isEmpty {
            fullPath = sanitizeFolderName(name)
        } else {
            fullPath = sanitizeFolderName(parent + folderSep + name)
        }

        guard !fullPath.isEmpty else {
            errorMessage = "Folder name is required."
            return
        }

        guard !folders.contains(fullPath) else {
            errorMessage = "Folder '\(fullPath)' already exists."
            return
        }

        // Auto-create intermediate parent folders.
        let parts = fullPath.components(separatedBy: folderSep)
        for i in 1...parts.count {
            let ancestor = parts[0..<i].joined(separator: folderSep)
            if !folders.contains(ancestor) {
                folders.append(ancestor)
            }
        }

        saveFolders()
    }

    /// Rename a folder and update all descendant paths and site assignments.
    func renameFolder(oldName: String, newName: String) {
        guard !oldName.isEmpty, !newName.isEmpty else {
            errorMessage = "Both old and new folder names are required."
            return
        }
        guard folders.contains(oldName) else {
            errorMessage = "Folder '\(oldName)' not found."
            return
        }
        guard !folders.contains(newName) else {
            errorMessage = "Folder '\(newName)' already exists."
            return
        }

        let oldPrefix = oldName + folderSep
        folders = folders.map { f in
            if f == oldName { return newName }
            if f.hasPrefix(oldPrefix) { return newName + f.dropFirst(oldName.count) }
            return f
        }

        saveFolders()

        // Update site folder assignments.
        for site in sites {
            if site.folder == oldName {
                var updated = site
                updated.folder = newName
                updateSite(updated)
            } else if site.folder.hasPrefix(oldPrefix) {
                var updated = site
                updated.folder = newName + site.folder.dropFirst(oldName.count)
                updateSite(updated)
            }
        }
    }

    /// Delete a folder and all subfolders, moving sites back to root.
    func deleteFolder(name: String) {
        let prefix = name + folderSep
        let removed = Set(folders.filter { $0 == name || $0.hasPrefix(prefix) })
        folders.removeAll { removed.contains($0) }
        saveFolders()

        // Move sites in removed folders back to root.
        for site in sites where removed.contains(site.folder) {
            var updated = site
            updated.folder = ""
            updateSite(updated)
        }
    }

    /// Move a site into (or out of) a folder.
    func moveSite(siteID: String, toFolder folder: String) {
        guard var site = sites.first(where: { $0.id == siteID }) else { return }
        site.folder = folder
        updateSite(site)
    }

    /// Persist a new folder ordering.
    func reorderFolders(_ newOrder: [String]) {
        guard Set(newOrder) == Set(folders), newOrder.count == Set(newOrder).count else {
            errorMessage = "Folder list must contain exactly the same folders."
            return
        }
        folders = newOrder
        saveFolders()
    }

    /// Reorder root-level folder nodes via drag-and-drop.
    ///
    /// Moves root folders (and their descendants) within the flat `folders`
    /// array while preserving each subtree's internal order.
    func moveRootFolders(from source: IndexSet, to destination: Int) {
        var rootPaths = folderTree.map(\.path)
        rootPaths.move(fromOffsets: source, toOffset: destination)

        // Rebuild flat order: each root path followed by its subfolders.
        var newOrder: [String] = []
        for rootPath in rootPaths {
            if folders.contains(rootPath) {
                newOrder.append(rootPath)
            }
            let prefix = rootPath + folderSep
            for f in folders where f.hasPrefix(prefix) {
                if !newOrder.contains(f) {
                    newOrder.append(f)
                }
            }
        }

        guard Set(newOrder) == Set(folders) else { return }
        folders = newOrder
        saveFolders()
    }

    /// Reorder child folders within a parent via drag-and-drop.
    ///
    /// Moves direct children of *parent* while preserving grandchildren order.
    func moveChildFolders(parent: String, from source: IndexSet, to destination: Int) {
        let prefix = parent + folderSep

        // Direct children: paths under prefix with no further separators.
        var directChildren = folders.filter { f in
            guard f.hasPrefix(prefix) else { return false }
            let remainder = f.dropFirst(prefix.count)
            return !remainder.contains(folderSep)
        }

        directChildren.move(fromOffsets: source, toOffset: destination)

        // Rebuild flat order preserving subtrees.
        var newOrder: [String] = []
        for f in folders {
            // Skip anything under this parent — we'll re-insert in new order.
            if f.hasPrefix(prefix) { continue }
            newOrder.append(f)

            // After the parent itself, insert the reordered children + subtrees.
            if f == parent {
                for childPath in directChildren {
                    newOrder.append(childPath)
                    let childPrefix = childPath + folderSep
                    for sub in folders where sub.hasPrefix(childPrefix) {
                        newOrder.append(sub)
                    }
                }
            }
        }

        guard Set(newOrder) == Set(folders) else { return }
        folders = newOrder
        saveFolders()
    }

    // MARK: - Connection Launch

    /// Launch a terminal session for a site.
    func launchSession(site: Site) {
        do {
            try terminal.launchSession(site: site)
        } catch {
            errorMessage = "Failed to launch terminal: \(error.localizedDescription)"
        }
    }

    /// Quick-connect by parsing user@host:port.
    func quickConnect(raw: String) {
        var host = raw.trimmingCharacters(in: .whitespaces)
        var username = ""
        var port = 22

        if host.contains("@") {
            let parts = host.split(separator: "@", maxSplits: 1)
            username = String(parts[0])
            host = String(parts[1])
        }
        if host.contains(":") {
            let parts = host.split(separator: ":", maxSplits: 1)
            host = String(parts[0])
            if let p = Int(parts[1]) {
                port = p
            } else {
                errorMessage = "Invalid port: \(parts[1])"
                return
            }
        }

        do {
            try terminal.launchSSH(hostname: host, port: port, username: username)
        } catch {
            errorMessage = "Failed to launch terminal: \(error.localizedDescription)"
        }
    }

    // MARK: - Export / Import

    /// Export all sessions and folders to JSON (credentials stripped).
    func exportData() -> Data? {
        let credentialFields: Set<String> = ["password", "key_path"]

        var exportedSites: [[String: Any]] = []
        for site in sites {
            let data = try? JSONEncoder().encode(site)
            guard let data, var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for field in credentialFields {
                dict.removeValue(forKey: field)
            }
            exportedSites.append(dict)
        }

        let payload: [String: Any] = [
            "connector_export": true,
            "version": 1,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "folders": folders,
            "sites": exportedSites,
        ]

        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    /// Import sessions and folders from JSON data.
    func importData(_ data: Data) -> (imported: Int, skipped: Int) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["connector_export"] as? Bool == true else {
            errorMessage = "File is not a valid Connector export."
            return (0, 0)
        }

        // Import folders
        if let importFolders = payload["folders"] as? [String] {
            let currentSet = Set(folders)
            for fname in importFolders where !fname.isEmpty && !currentSet.contains(fname) {
                folders.append(fname)
            }
            saveFolders()
        }

        // Import sites
        guard let importSites = payload["sites"] as? [[String: Any]] else {
            return (0, 0)
        }

        let existingKeys = Set(sites.map { "\($0.name)|\($0.hostname)|\($0.connectionProtocol.rawValue)" })
        var importedCount = 0
        var skippedCount = 0

        let decoder = JSONDecoder()
        for var siteDict in importSites {
            guard siteDict["name"] != nil else {
                skippedCount += 1
                continue
            }

            // Ensure credentials are blank
            siteDict["password"] = ""
            siteDict["key_path"] = ""
            // Drop old ID so a fresh UUID is generated
            siteDict.removeValue(forKey: "id")
            siteDict["id"] = UUID().uuidString

            let name = siteDict["name"] as? String ?? ""
            let hostname = siteDict["hostname"] as? String ?? ""
            let proto = siteDict["protocol"] as? String ?? "ssh2"
            let key = "\(name)|\(hostname)|\(proto)"

            if existingKeys.contains(key) {
                skippedCount += 1
                continue
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: siteDict),
                  let site = try? decoder.decode(Site.self, from: jsonData) else {
                skippedCount += 1
                continue
            }

            do {
                try storage.createSite(site)
                importedCount += 1
            } catch {
                skippedCount += 1
            }
        }

        reload()
        return (importedCount, skippedCount)
    }

    // MARK: - Private Helpers

    private func saveFolders() {
        do {
            try settings.update { s in
                s.folders = folders
            }
        } catch {
            errorMessage = "Failed to save folders: \(error.localizedDescription)"
        }
    }

    private func sanitizeFolderName(_ name: String) -> String {
        name.components(separatedBy: folderSep)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: folderSep)
    }

    /// Build a recursive folder tree from a flat list of folder paths.
    ///
    /// Uses a two-phase approach to handle struct value semantics correctly:
    /// Phase 1 — collect base nodes and parent→child path relationships.
    /// Phase 2 — recursively construct each node so children are fully resolved.
    private func buildFolderTree(folderPaths: [String], allSites: [Site]) -> [FolderNode] {
        // Phase 1: create base nodes with sites assigned.
        var baseNodes: [String: FolderNode] = [:]
        var orderedPaths: [String] = []

        for path in folderPaths {
            let name = path.split(separator: Character(folderSep)).last.map(String.init) ?? path
            baseNodes[path] = FolderNode(id: path, name: name, path: path, children: [], sites: [])
            orderedPaths.append(path)
        }

        for site in allSites {
            if !site.folder.isEmpty, baseNodes[site.folder] != nil {
                baseNodes[site.folder]?.sites.append(site)
            }
        }

        // Determine parent→child path relationships.
        var childPathsOf: [String: [String]] = [:]
        var rootPaths: [String] = []

        for path in orderedPaths {
            let parentPath: String
            if path.contains(folderSep) {
                parentPath = String(path[..<path.lastIndex(of: Character(folderSep))!])
            } else {
                parentPath = ""
            }

            if !parentPath.isEmpty, baseNodes[parentPath] != nil {
                childPathsOf[parentPath, default: []].append(path)
            } else {
                rootPaths.append(path)
            }
        }

        // Phase 2: recursively build each node so children are fully resolved
        // (avoids struct copy-before-children-assigned problem).
        func buildNode(for path: String) -> FolderNode? {
            guard var node = baseNodes[path] else { return nil }
            node.children = (childPathsOf[path] ?? []).compactMap { buildNode(for: $0) }
            return node
        }

        return rootPaths.compactMap { buildNode(for: $0) }
    }
}
