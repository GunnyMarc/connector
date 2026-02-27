/// SFTP file browser view for remote directory navigation and file transfer.
///
/// Mirrors the Python app's sftp.html — lists remote files with download/upload
/// support. Uses TerminalService's SSH subprocess approach for SFTP operations.

import SwiftUI

struct SFTPBrowserView: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let site: Site

    @State private var currentPath = ""
    @State private var files: [RemoteFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var parentPath: String?
    @State private var loadingMessage = "Loading..."
    @State private var showDeleteConfirm = false
    @State private var fileToDelete: RemoteFile?
    @State private var editingPath = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SFTP: \(site.name)")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Path bar
            HStack {
                if parentPath != nil {
                    Button(action: navigateUp) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }

                TextField("~", text: $editingPath)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit { navigateTo(editingPath) }

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)

                Menu {
                    Button("File...", action: uploadFile)
                    Button("Directory...", action: uploadDirectory)
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // File list
            if isLoading {
                ProgressView(loadingMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text("Connection Error")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if files.isEmpty {
                Text("Empty directory")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }
        }
        .frame(minWidth: 500, idealWidth: 700, minHeight: 350, idealHeight: 500)
        .onAppear {
            currentPath = site.sftpRoot.isEmpty ? "" : site.sftpRoot
            editingPath = currentPath
            refresh()
        }
        .alert("Confirm Delete", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let file = fileToDelete {
                    performDelete(file)
                }
            }
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
        } message: {
            if let file = fileToDelete {
                if file.isDirectory {
                    Text("Delete directory \"\(file.name)\" and all of its contents? This cannot be undone.")
                } else {
                    Text("Delete \"\(file.name)\"? This cannot be undone.")
                }
            }
        }
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(files) { file in
                HStack {
                    Image(systemName: file.isDirectory ? "folder.fill" : fileIcon(file.name))
                        .foregroundStyle(file.isDirectory ? .blue : .secondary)
                        .frame(width: 20)

                    Text(file.name)
                        .lineLimit(1)

                    Spacer()

                    if !file.isDirectory {
                        Text(formatSize(file.size))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Text(file.modified)
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .frame(width: 120, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if file.isDirectory {
                        navigateTo(file.path)
                    } else {
                        downloadFile(file)
                    }
                }
                .contextMenu {
                    if file.isDirectory {
                        Button("Open") { navigateTo(file.path) }
                        Button("Download") { downloadDirectory(file) }
                        Divider()
                        Button("Delete", role: .destructive) { confirmDelete(file) }
                    } else {
                        Button("Download") { downloadFile(file) }
                        Divider()
                        Button("Delete", role: .destructive) { confirmDelete(file) }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        loadingMessage = "Loading..."
        isLoading = true
        errorMessage = nil
        let terminal = store.terminal
        let path = currentPath
        let currentSite = site

        Task.detached {
            do {
                let resolvedPath = try terminal.sftpNormalize(site: currentSite, remotePath: path)
                let listing = try terminal.sftpList(site: currentSite, remotePath: resolvedPath)

                let parent: String?
                if resolvedPath == "/" {
                    parent = nil
                } else {
                    let p = (resolvedPath as NSString).deletingLastPathComponent
                    parent = p.isEmpty ? "/" : p
                }

                await MainActor.run {
                    currentPath = resolvedPath
                    editingPath = resolvedPath
                    files = listing
                    parentPath = parent
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func navigateTo(_ path: String) {
        currentPath = path
        refresh()
    }

    private func navigateUp() {
        if let parent = parentPath {
            navigateTo(parent)
        }
    }

    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.title = "Save File"
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadingMessage = "Downloading file..."
        isLoading = true
        let terminal = store.terminal
        let currentSite = site

        Task.detached {
            do {
                try terminal.sftpDownload(site: currentSite, remotePath: file.path, localPath: url.path)
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Download failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func downloadDirectory(_ file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination for Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadingMessage = "Downloading directory..."
        isLoading = true
        let terminal = store.terminal
        let currentSite = site

        Task.detached {
            do {
                try terminal.sftpDownloadDirectory(
                    site: currentSite,
                    remotePath: file.path,
                    localPath: url.path,
                )
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Directory download failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func confirmDelete(_ file: RemoteFile) {
        fileToDelete = file
        showDeleteConfirm = true
    }

    private func performDelete(_ file: RemoteFile) {
        loadingMessage = file.isDirectory ? "Deleting directory..." : "Deleting file..."
        isLoading = true
        let terminal = store.terminal
        let currentSite = site

        Task.detached {
            do {
                if file.isDirectory {
                    try terminal.sftpDeleteDirectory(
                        site: currentSite,
                        remotePath: file.path,
                    )
                } else {
                    try terminal.sftpDelete(
                        site: currentSite,
                        remotePath: file.path,
                    )
                }
                await MainActor.run {
                    isLoading = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Delete failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.title = "Upload File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let remotePath = "\(currentPath)/\(url.lastPathComponent)"
            .replacingOccurrences(of: "//", with: "/")

        loadingMessage = "Uploading file..."
        isLoading = true
        let terminal = store.terminal
        let currentSite = site

        Task.detached {
            do {
                try terminal.sftpUpload(
                    site: currentSite,
                    localPath: url.path,
                    remotePath: remotePath,
                )
                await MainActor.run {
                    isLoading = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Upload failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func uploadDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Upload Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let remotePath = "\(currentPath)/\(url.lastPathComponent)"
            .replacingOccurrences(of: "//", with: "/")

        loadingMessage = "Uploading directory..."
        isLoading = true
        let terminal = store.terminal
        let currentSite = site

        Task.detached {
            do {
                try terminal.sftpUploadDirectory(
                    site: currentSite,
                    localPath: url.path,
                    remotePath: remotePath,
                )
                await MainActor.run {
                    isLoading = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Directory upload failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log", "csv":     return "doc.text"
        case "py", "swift", "js", "ts", "sh", "rb", "go", "rs": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "xml":  return "curlybraces"
        case "zip", "tar", "gz", "bz2":     return "doc.zipper"
        case "jpg", "jpeg", "png", "gif":   return "photo"
        case "pdf":                          return "doc.richtext"
        default:                             return "doc"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
