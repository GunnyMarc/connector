/// SFTP file browser view for remote directory navigation and file transfer.
///
/// Mirrors the Python app's sftp.html — lists remote files with download/upload
/// support. Uses TerminalService's SSH subprocess approach for SFTP operations.
/// Provides verbose transfer output, a progress bar with percentage, and a
/// "File transfer complete" dialog on completion.

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

    // Transfer progress state
    @State private var isTransferring = false
    @State private var transferProgress: Double = 0.0
    @State private var transferLog: [String] = []
    @State private var transferTitle = ""
    @State private var showTransferComplete = false

    var body: some View {
        ZStack {
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
                    .disabled(isLoading || isTransferring)

                    Menu {
                        Button("File...", action: uploadFile)
                        Button("Directory...", action: uploadDirectory)
                    } label: {
                        Label("Upload", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isTransferring)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // File list
                if isLoading && !isTransferring {
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

            // Transfer progress overlay
            if isTransferring {
                transferOverlay
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
        .alert("File transfer complete", isPresented: $showTransferComplete) {
            Button("OK") {
                refresh()
            }
        }
    }

    // MARK: - Transfer Progress Overlay

    private var transferOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(transferTitle)
                        .font(.headline)
                    Spacer()
                }

                // Verbose log
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(transferLog.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 80)
                    .padding(6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onChange(of: transferLog.count) { _, _ in
                        if let last = transferLog.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }

                // Progress bar
                ProgressView(value: transferProgress, total: 1.0)
                    .progressViewStyle(.linear)

                Text("\(Int(transferProgress * 100))% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
            .frame(width: 420)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 10)
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

    // MARK: - Transfer Helpers

    /// Begin a tracked transfer, updating progress state on the main actor.
    private func beginTransfer(title: String) {
        isTransferring = true
        transferProgress = 0.0
        transferLog = []
        transferTitle = title
    }

    /// Progress callback that dispatches updates to the main actor.
    ///
    /// Returns a `@Sendable` closure suitable for use in `Task.detached`.
    private func makeProgressHandler() -> TerminalService.TransferProgress {
        return { transferred, total, message in
            Task { @MainActor in
                if total > 0 {
                    transferProgress = Double(transferred) / Double(total)
                }
                transferLog.append(message)
            }
        }
    }

    /// Finish a transfer: hide the overlay and show the completion alert.
    private func finishTransfer() {
        isTransferring = false
        showTransferComplete = true
    }

    /// Finish a transfer with an error message.
    private func failTransfer(_ message: String) {
        isTransferring = false
        errorMessage = message
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

        beginTransfer(title: "Downloading \(file.name)...")
        let terminal = store.terminal
        let currentSite = site
        let progress = makeProgressHandler()

        Task.detached {
            do {
                let totalSize = try terminal.sftpRemoteSize(
                    site: currentSite, remotePath: file.path
                )
                await MainActor.run {
                    let label = ByteCountFormatter.string(
                        fromByteCount: totalSize, countStyle: .file
                    )
                    transferLog.append("Source size: \(label)")
                }
                try terminal.sftpDownloadWithProgress(
                    site: currentSite,
                    remotePath: file.path,
                    localPath: url.path,
                    totalSize: totalSize,
                    onProgress: progress
                )
                await MainActor.run { finishTransfer() }
            } catch {
                await MainActor.run {
                    failTransfer("Download failed: \(error.localizedDescription)")
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

        beginTransfer(title: "Downloading \(file.name)/...")
        let terminal = store.terminal
        let currentSite = site
        let progress = makeProgressHandler()

        Task.detached {
            do {
                try terminal.sftpDownloadDirectoryWithProgress(
                    site: currentSite,
                    remotePath: file.path,
                    localPath: url.path,
                    onProgress: progress
                )
                await MainActor.run { finishTransfer() }
            } catch {
                await MainActor.run {
                    failTransfer("Directory download failed: \(error.localizedDescription)")
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
        panel.title = "Upload Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        let fileCount = urls.count
        let title = fileCount == 1
            ? "Uploading \(urls[0].lastPathComponent)..."
            : "Uploading \(fileCount) files..."

        beginTransfer(title: title)
        let terminal = store.terminal
        let currentSite = site
        let basePath = currentPath

        Task.detached {
            do {
                // Calculate total size across all selected files.
                let fm = FileManager.default
                var fileSizes: [(url: URL, remotePath: String, size: Int64)] = []
                var totalSize: Int64 = 0

                for url in urls {
                    let attrs = try fm.attributesOfItem(atPath: url.path)
                    let size = (attrs[.size] as? Int64) ?? 0
                    let remote = "\(basePath)/\(url.lastPathComponent)"
                        .replacingOccurrences(of: "//", with: "/")
                    fileSizes.append((url: url, remotePath: remote, size: size))
                    totalSize += size
                }

                await MainActor.run {
                    let label = ByteCountFormatter.string(
                        fromByteCount: totalSize, countStyle: .file
                    )
                    transferLog.append(
                        "Selected \(fileCount) file(s), total \(label)"
                    )
                }

                // Upload each file, tracking cumulative progress.
                var completedBytes: Int64 = 0

                for (index, entry) in fileSizes.enumerated() {
                    let filename = entry.url.lastPathComponent
                    await MainActor.run {
                        transferLog.append(
                            "(\(index + 1)/\(fileCount)) \(filename)"
                        )
                    }

                    let offset = completedBytes
                    let overallTotal = totalSize

                    try terminal.sftpUploadWithProgress(
                        site: currentSite,
                        localPath: entry.url.path,
                        remotePath: entry.remotePath,
                        totalSize: entry.size,
                        onProgress: { transferred, _, message in
                            Task { @MainActor in
                                let overall = offset + transferred
                                if overallTotal > 0 {
                                    transferProgress = Double(overall) / Double(overallTotal)
                                }
                                transferLog.append(message)
                            }
                        }
                    )

                    completedBytes += entry.size
                    await MainActor.run {
                        transferProgress = Double(completedBytes) / Double(totalSize)
                    }
                }

                await MainActor.run { finishTransfer() }
            } catch {
                await MainActor.run {
                    failTransfer("Upload failed: \(error.localizedDescription)")
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

        beginTransfer(title: "Uploading \(url.lastPathComponent)/...")
        let terminal = store.terminal
        let currentSite = site
        let progress = makeProgressHandler()

        Task.detached {
            do {
                try terminal.sftpUploadDirectoryWithProgress(
                    site: currentSite,
                    localPath: url.path,
                    remotePath: remotePath,
                    onProgress: progress
                )
                await MainActor.run { finishTransfer() }
            } catch {
                await MainActor.run {
                    failTransfer("Directory upload failed: \(error.localizedDescription)")
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
