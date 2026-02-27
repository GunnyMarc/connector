/// Sidebar view with folder tree, site list, search, drag-and-drop, and context menus.
///
/// Mirrors the Python app's sidebar with folder grouping, drag-and-drop
/// reordering of folders and sites, and context menus for CRUD operations.

import SwiftUI

struct SidebarView: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    @Binding var showNewSiteForm: Bool
    @Binding var showQuickConnect: Bool
    @Binding var editingSite: Site?

    @State private var newFolderName = ""
    @State private var showNewFolderAlert = false
    @State private var newFolderParent = ""

    @State private var renamingFolder: String?
    @State private var renameText = ""

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedSiteID) {
            // Folder tree — root-level nodes with drag reorder
            ForEach(store.folderTree) { node in
                FolderSectionView(
                    node: node,
                    editingSite: $editingSite,
                    renamingFolder: $renamingFolder,
                    renameText: $renameText,
                    newFolderName: $newFolderName,
                    newFolderParent: $newFolderParent,
                    showNewFolderAlert: $showNewFolderAlert
                )
            }
            .onMove { source, destination in
                store.moveRootFolders(from: source, to: destination)
            }

            // Root sites (no folder) — drop target for moving sites to root
            Section("Sites") {
                ForEach(store.rootSites) { site in
                    SiteRowView(
                        site: site,
                        editingSite: $editingSite
                    )
                }
            }
            .dropDestination(for: String.self) { items, _ in
                for siteID in items {
                    store.moveSite(siteID: siteID, toFolder: "")
                }
                return !items.isEmpty
            } isTargeted: { isTargeted in
                // Visual feedback handled by SwiftUI highlight
            }
        }
        .id(store.refreshToken)
        .searchable(text: Bindable(store).searchText, prompt: "Search sites...")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { showNewSiteForm = true }) {
                    Label("New Site", systemImage: "plus")
                }

                Button(action: {
                    newFolderParent = ""
                    newFolderName = ""
                    showNewFolderAlert = true
                }) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Button(action: { store.reload() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Menu {
                    Button("Quick Connect...", action: { showQuickConnect = true })
                    Divider()
                    Button("Settings...", action: { openSettings() })
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                if !newFolderName.isEmpty {
                    store.createFolder(name: newFolderName, parent: newFolderParent)
                    newFolderName = ""
                    newFolderParent = ""
                }
            }
            Button("Cancel", role: .cancel) {
                newFolderName = ""
                newFolderParent = ""
            }
        } message: {
            if newFolderParent.isEmpty {
                Text("Enter a name for the new folder.")
            } else {
                Text("Enter a name for the new subfolder in '\(newFolderParent)'.")
            }
        }
        .alert("Rename Folder", isPresented: .init(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let old = renamingFolder, !renameText.isEmpty {
                    // Build new full path: replace only the last segment.
                    let newFullPath: String
                    if old.contains("/") {
                        let parent = String(old[..<old.lastIndex(of: "/")!])
                        newFullPath = parent + "/" + renameText
                    } else {
                        newFullPath = renameText
                    }
                    store.renameFolder(oldName: old, newName: newFullPath)
                }
                renamingFolder = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                renamingFolder = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for '\(renamingFolder ?? "")'.")
        }
    }
}

// MARK: - Folder Section (separate struct for recursive rendering)

/// Renders a folder disclosure group with recursive children, drag-and-drop
/// support for site drops and folder reordering.
///
/// Extracted into its own struct to avoid the Swift compiler limitation
/// where opaque return types cannot be inferred for recursive functions.
struct FolderSectionView: View {
    @Environment(SiteStore.self) private var store

    let node: FolderNode
    @Binding var editingSite: Site?
    @Binding var renamingFolder: String?
    @Binding var renameText: String
    @Binding var newFolderName: String
    @Binding var newFolderParent: String
    @Binding var showNewFolderAlert: Bool

    @State private var isDropTargeted = false

    var body: some View {
        DisclosureGroup {
            // Child folders (recursive) — with reorder support
            ForEach(node.children) { child in
                FolderSectionView(
                    node: child,
                    editingSite: $editingSite,
                    renamingFolder: $renamingFolder,
                    renameText: $renameText,
                    newFolderName: $newFolderName,
                    newFolderParent: $newFolderParent,
                    showNewFolderAlert: $showNewFolderAlert
                )
            }
            .onMove { source, destination in
                store.moveChildFolders(
                    parent: node.path,
                    from: source,
                    to: destination
                )
            }

            // Sites in this folder
            ForEach(node.sites) { site in
                SiteRowView(
                    site: site,
                    editingSite: $editingSite
                )
            }
        } label: {
            Label(node.name, systemImage: "folder")
                .background(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                )
                .cornerRadius(4)
                .contextMenu {
                    Button("New Subfolder...") {
                        newFolderParent = node.path
                        newFolderName = ""
                        showNewFolderAlert = true
                    }

                    Divider()

                    Button("Rename...") {
                        // Pre-fill with the display name (last segment).
                        renameText = node.name
                        renamingFolder = node.path
                    }

                    Divider()

                    Button("Delete Folder", role: .destructive) {
                        store.deleteFolder(name: node.path)
                    }
                }
        }
        .dropDestination(for: String.self) { items, _ in
            for siteID in items {
                store.moveSite(siteID: siteID, toFolder: node.path)
            }
            return !items.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}

// MARK: - Site Row

/// A single site entry in the sidebar list, draggable for folder reassignment.
struct SiteRowView: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    let site: Site
    @Binding var editingSite: Site?

    var body: some View {
        HStack {
            protocolIcon(site.connectionProtocol)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .lineLimit(1)
                if !site.hostname.isEmpty {
                    Text(site.hostname)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .tag(site.id)
        .draggable(site.id)
        .contextMenu {
            Button("Connect") {
                store.launchSession(site: site)
            }

            if site.isSSH {
                Button("SFTP Browser...") {
                    openWindow(id: "sftp", value: site.id)
                }
            }

            Divider()

            Button("Edit...") {
                editingSite = site
            }

            Button("Duplicate") {
                store.duplicateSite(id: site.id)
            }

            Divider()

            // Move to folder submenu
            if !store.folders.isEmpty {
                Menu("Move to Folder") {
                    Button("Root (No Folder)") {
                        store.moveSite(siteID: site.id, toFolder: "")
                    }
                    Divider()
                    ForEach(store.folders, id: \.self) { folder in
                        Button(folder) {
                            store.moveSite(siteID: site.id, toFolder: folder)
                        }
                    }
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                store.deleteSite(id: site.id)
            }
        }
    }

    private func protocolIcon(_ proto: ConnectionProtocol) -> Image {
        switch proto {
        case .ssh2, .ssh1:  Image(systemName: "lock.shield")
        case .local:        Image(systemName: "terminal")
        case .raw:          Image(systemName: "network")
        case .telnet:       Image(systemName: "globe")
        case .serial:       Image(systemName: "cable.connector")
        }
    }
}
