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

                Text(currentPath.isEmpty ? "~" : currentPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)

                Button(action: uploadFile) {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // File list
            if isLoading {
                ProgressView("Loading...")
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
        .frame(width: 600, height: 450)
        .onAppear {
            currentPath = site.sftpRoot.isEmpty ? "" : site.sftpRoot
            refresh()
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
                    } else {
                        Button("Download") { downloadFile(file) }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
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

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.title = "Upload File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let remotePath = "\(currentPath)/\(url.lastPathComponent)".replacingOccurrences(of: "//", with: "/")

        isLoading = true
        let terminal = store.terminal
        let currentSite = site

        Task.detached {
            do {
                try terminal.sftpUpload(site: currentSite, localPath: url.path, remotePath: remotePath)
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
