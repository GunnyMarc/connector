/// Settings view with global defaults, export/import, and platform info.
///
/// Mirrors the Python app's settings.html — editable defaults plus
/// session export/import functionality.

import SwiftUI

struct SettingsView: View {
    @Environment(SiteStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var importResult: String?

    var body: some View {
        @Bindable var settingsStore = settingsStore

        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                // Connection defaults
                Section("Connection Defaults") {
                    TextField("Default Port", value: $settingsStore.settings.defaultPort, format: .number)
                        .frame(width: 100)
                    TextField("SSH Timeout (seconds)", value: $settingsStore.settings.sshTimeout, format: .number)
                        .frame(width: 100)
                    TextField("Command Timeout (seconds)", value: $settingsStore.settings.commandTimeout, format: .number)
                        .frame(width: 100)
                    TextField("Default Username", text: $settingsStore.settings.defaultUsername)
                    Picker("Default Auth Type", selection: $settingsStore.settings.defaultAuthType) {
                        Text("Password").tag("password")
                        Text("SSH Key").tag("key")
                    }
                    TextField("Default Key Path", text: $settingsStore.settings.defaultKeyPath)
                }

                // Platform info
                Section("Platform") {
                    LabeledContent("System", value: store.terminal.platformInfo.systemLabel)
                    LabeledContent("Terminal", value: store.terminal.platformInfo.terminal)
                    LabeledContent("sshpass", value: store.terminal.platformInfo.hasSshpass ? "Available" : "Not found")
                }

                // Export / Import
                Section("Data") {
                    HStack {
                        Button("Export Sessions...") {
                            exportSessions()
                        }

                        Button("Import Sessions...") {
                            importSessions()
                        }
                    }

                    if let result = importResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Export creates a JSON file with all sessions and folders. Credentials are stripped for security.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Save") {
                    settingsStore.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 500)
    }

    // MARK: - Export

    private func exportSessions() {
        guard let data = store.exportData() else {
            importResult = "Export failed."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Sessions"
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        panel.nameFieldStringValue = "connector_export_\(timestamp).json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url)
            importResult = "Exported successfully."
        } catch {
            importResult = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    private func importSessions() {
        let panel = NSOpenPanel()
        panel.title = "Import Sessions"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let (imported, skipped) = store.importData(data)

            var parts: [String] = []
            if imported > 0 { parts.append("\(imported) session(s) imported") }
            if skipped > 0 { parts.append("\(skipped) skipped (duplicate or invalid)") }
            if parts.isEmpty { parts.append("No sessions found in file") }
            importResult = parts.joined(separator: ". ") + "."
        } catch {
            importResult = "Import failed: \(error.localizedDescription)"
        }
    }
}
