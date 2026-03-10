/// Detail view for a selected site, showing connection info and action buttons.
///
/// Mirrors the Python app's ssh.html — displays site details with Connect,
/// SFTP, Edit, Duplicate, and Delete actions.

import SwiftUI

struct SiteDetailView: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    let site: Site
    @Binding var editingSite: Site?

    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(site.name)
                            .font(.title)
                        HStack(spacing: 8) {
                            protocolBadge
                            if !site.hostname.isEmpty {
                                Text("\(site.hostname):\(site.port)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Action buttons
                    HStack(spacing: 8) {
                        Button(action: { store.launchSession(site: site) }) {
                            Label("Connect", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        if site.hasTunnel {
                            Button(action: { store.launchTunnel(site: site) }) {
                                Label("Tunnel", systemImage: "lock.shield")
                            }
                        }

                        if site.isSSH {
                            Button(action: { openWindow(id: "sftp", value: site.id) }) {
                                Label("SFTP", systemImage: "folder")
                            }
                        }
                    }
                }

                Divider()

                // Connection details
                detailsGrid

                // Notes
                if !site.notes.isEmpty {
                    GroupBox("Notes") {
                        Text(site.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                // Management actions
                HStack(spacing: 12) {
                    Button("Edit") { editingSite = site }
                    Button("Duplicate") { store.duplicateSite(id: site.id) }
                    Spacer()
                    Button("Delete", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .padding(20)
        }
        .confirmationDialog(
            "Delete '\(site.name)'?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteSite(id: site.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Subviews

    private var protocolBadge: some View {
        Text(site.protocolLabel)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
    }

    private var detailsGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            if site.connectionProtocol.isNetwork {
                detailRow("Hostname", site.hostname)
                detailRow("Port", String(site.port))
            }

            if site.connectionProtocol.isSSH {
                detailRow("Username", site.username.isEmpty ? "(none)" : site.username)
                detailRow("Auth Type", site.authType.label)

                if site.authType == .password {
                    detailRow("Password", site.maskedPassword.isEmpty ? "(none)" : site.maskedPassword)
                } else {
                    detailRow("Key Path", site.keyPath.isEmpty ? "(none)" : site.keyPath)
                }

                if !site.sftpRoot.isEmpty {
                    detailRow("SFTP Root", site.sftpRoot)
                }
            }

            if site.connectionProtocol == .serial {
                detailRow("Serial Port", site.serialPort.isEmpty ? "/dev/ttyUSB0" : site.serialPort)
                detailRow("Baud Rate", String(site.serialBaud))
            }

            if site.hasTunnel {
                detailRow("Tunnel", "\(site.tunnelSourcePort) -> localhost:\(site.tunnelDestPort)")
                detailRow("Tunnel User", site.tunnelUsername)
                if !site.tunnelKeyPath.isEmpty {
                    detailRow("Tunnel Key", site.tunnelKeyPath)
                }
            }

            if !site.folder.isEmpty {
                detailRow("Folder", site.folder)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}
