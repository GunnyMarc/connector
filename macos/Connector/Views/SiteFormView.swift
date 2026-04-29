/// Create/edit form for site connections.
///
/// Mirrors the Python app's site_form.html with protocol-specific field
/// visibility (e.g. serial port/baud only for Serial protocol).

import SwiftUI

struct SiteFormView: View {
    @Environment(SiteStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    /// Pass `nil` to create a new site, or an existing site to edit it.
    let site: Site?

    @State private var draft: Site
    @State private var isNew: Bool

    init(site: Site?) {
        self.site = site
        if let site {
            _draft = State(initialValue: site)
            _isNew = State(initialValue: false)
        } else {
            _draft = State(initialValue: Site())
            _isNew = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "New Site" : "Edit Site")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            Form {
                // Basic info
                Section("Connection") {
                    TextField("Name", text: $draft.name)

                    Picker("Protocol", selection: $draft.connectionProtocol) {
                        ForEach(ConnectionProtocol.allCases) { proto in
                            Text(proto.label).tag(proto)
                        }
                    }

                    if draft.connectionProtocol.isNetwork {
                        TextField("Hostname", text: $draft.hostname)
                        TextField("Port", value: $draft.port, format: .number)
                            .frame(width: 100)
                    }

                    if draft.connectionProtocol == .serial {
                        TextField("Serial Port", text: $draft.serialPort)
                            .help("e.g. /dev/tty.usbserial-110")
                        TextField("Baud Rate", value: $draft.serialBaud, format: .number)
                            .frame(width: 100)
                    }
                }

                // Authentication (SSH only)
                if draft.connectionProtocol.isSSH {
                    Section("Authentication") {
                        TextField("Username", text: $draft.username)

                        Picker("Auth Type", selection: $draft.authType) {
                            ForEach(AuthType.allCases) { type in
                                Text(type.label).tag(type)
                            }
                        }

                        if draft.authType == .password {
                            SecureField("Password", text: $draft.password)
                        } else {
                            HStack {
                                TextField("Key Path", text: $draft.keyPath)
                                Button("Browse...") {
                                    browseForKey()
                                }
                            }
                        }
                    }

                    Section("SFTP") {
                        TextField("SFTP Root Path", text: $draft.sftpRoot)
                            .help("Absolute path where SFTP browser starts (empty = home)")
                    }
                }

                // Organization
                Section("Organization") {
                    Picker("Folder", selection: $draft.folder) {
                        Text("(No Folder)").tag("")
                        ForEach(store.folders, id: \.self) { folder in
                            Text(folder).tag(folder)
                        }
                    }

                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 450, minHeight: 350)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(isNew ? "Create" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
        .onAppear {
            applyDefaults()
        }
    }

    // MARK: - Actions

    private func save() {
        if isNew {
            store.createSite(draft)
        } else {
            store.updateSite(draft)
        }
        dismiss()
    }

    private func applyDefaults() {
        guard isNew else { return }
        let s = settingsStore.settings
        draft.port = s.defaultPort
        draft.username = s.defaultUsername
        if let authType = AuthType(rawValue: s.defaultAuthType) {
            draft.authType = authType
        }
        if draft.authType == .key {
            draft.keyPath = s.defaultKeyPath
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
            draft.keyPath = url.path
        }
    }
}
