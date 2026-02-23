/// Settings view with global defaults, export/import, and platform info.
///
/// Mirrors the Python app's settings.html layout:
///   1. Platform info (read-only)
///   2. Connection Defaults (port, username, auth type, key path)
///   3. Timeouts (connection, command)
///   4. Import / Export
///   5. Save / Cancel / Reset

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SiteStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore

    @State private var statusMessage: String?
    @State private var statusIsError: Bool = false
    @State private var showImportConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var showResetConfirmation = false

    var body: some View {
        @Bindable var settingsStore = settingsStore

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // ── Platform (read-only) ─────────────────────────
                    platformSection

                    Divider()

                    // ── Connection Defaults ───────────────────────────
                    connectionDefaultsSection

                    Divider()

                    // ── Timeouts ──────────────────────────────────────
                    timeoutsSection

                    Divider()

                    // ── Import / Export ───────────────────────────────
                    importExportSection

                    // ── Status message ────────────────────────────────
                    if let msg = statusMessage {
                        HStack(spacing: 6) {
                            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(statusIsError ? .orange : .green)
                            Text(msg)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // ── Footer ───────────────────────────────────────────────
            HStack {
                Button("Reset to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }

                Spacer()

                Button("Save") {
                    saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 620)
        .confirmationDialog(
            "Reset to Defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                settingsStore.resetToDefaults()
                store.reload()
                statusMessage = "Settings reset to defaults."
                statusIsError = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all settings to their factory defaults. Folders and sessions are not affected.")
        }
        .confirmationDialog(
            "Import Sessions?",
            isPresented: $showImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Import") {
                performImport()
            }
            Button("Cancel", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("Duplicate sessions (same name + hostname + protocol) will be skipped. Imported sessions will not include credentials.")
        }
    }

    // MARK: - Platform Section

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Platform")
                .font(.headline)
                .foregroundStyle(.primary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("OS")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(store.terminal.platformInfo.systemLabel)
                        .gridColumnAlignment(.leading)
                }
                GridRow {
                    Text("Terminal")
                        .foregroundStyle(.secondary)
                    Text(store.terminal.platformInfo.terminal)
                }
                GridRow {
                    Text("sshpass")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if store.terminal.platformInfo.hasSshpass {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Installed")
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Not found")
                        }
                    }
                }
            }

            Text("Sessions: \(store.sites.count)  |  Folders: \(store.folders.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Connection Defaults Section

    @ViewBuilder
    private var connectionDefaultsSection: some View {
        @Bindable var settingsStore = settingsStore

        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Defaults")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Applied when creating new sessions.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                // SSH Port
                GridRow {
                    Text("SSH Port")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .frame(width: 110, alignment: .trailing)
                    TextField("22", value: $settingsStore.settings.defaultPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .gridColumnAlignment(.leading)
                }

                // Username
                GridRow {
                    Text("Username")
                        .foregroundStyle(.secondary)
                    TextField("(none)", text: $settingsStore.settings.defaultUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 250)
                }

                // Auth Type
                GridRow {
                    Text("Auth Type")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settingsStore.settings.defaultAuthType) {
                        Text("Password").tag("password")
                        Text("SSH Key").tag("key")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                }

                // Default Key Path
                GridRow {
                    Text("Key Path")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("~/.ssh/id_rsa", text: $settingsStore.settings.defaultKeyPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 250)
                        Button("Browse...") {
                            browseForKey()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Timeouts Section

    @ViewBuilder
    private var timeoutsSection: some View {
        @Bindable var settingsStore = settingsStore

        VStack(alignment: .leading, spacing: 12) {
            Text("Timeouts")
                .font(.headline)
                .foregroundStyle(.primary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Connection")
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    HStack(spacing: 6) {
                        TextField("10", value: $settingsStore.settings.sshTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("seconds")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                }

                GridRow {
                    Text("Command")
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    HStack(spacing: 6) {
                        TextField("30", value: $settingsStore.settings.commandTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("seconds")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Import / Export Section

    private var importExportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import / Export")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Export sessions to a JSON file for backup or sharing. Credentials (passwords and SSH key paths) are **not** included in the export and must be entered separately after import.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Button {
                    exportSessions()
                } label: {
                    Label("Export Sessions", systemImage: "square.and.arrow.down")
                }

                Button {
                    chooseImportFile()
                } label: {
                    Label("Import Sessions", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Actions

    private func saveSettings() {
        if settingsStore.save() {
            // Reload the SiteStore so folder changes propagate.
            store.reload()
            statusMessage = "Settings saved."
            statusIsError = false
        } else {
            statusMessage = settingsStore.errorMessage ?? "Save failed."
            statusIsError = true
        }
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Key"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
        if FileManager.default.fileExists(atPath: sshDir) {
            panel.directoryURL = URL(fileURLWithPath: sshDir)
        }

        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.defaultKeyPath = url.path
        }
    }

    // MARK: - Export

    private func exportSessions() {
        guard let data = store.exportData() else {
            statusMessage = "Export failed: no data to export."
            statusIsError = true
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Sessions"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "connector_export_\(timestamp).json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url)
            statusMessage = "Exported \(store.sites.count) session(s) successfully."
            statusIsError = false
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    // MARK: - Import

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Sessions"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        pendingImportURL = url
        showImportConfirmation = true
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil

        do {
            let data = try Data(contentsOf: url)
            let (imported, skipped) = store.importData(data)

            var parts: [String] = []
            if imported > 0 { parts.append("\(imported) session(s) imported") }
            if skipped > 0 { parts.append("\(skipped) skipped (duplicate or invalid)") }
            if parts.isEmpty { parts.append("No sessions found in file") }

            statusMessage = parts.joined(separator: ". ") + "."
            statusIsError = false

            // Reload settings too in case folders changed.
            settingsStore.reload()
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }
}
