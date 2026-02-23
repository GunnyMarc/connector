/// Quick connect sheet for fast SSH connections.
///
/// Mirrors the Python app's quick-connect form — parses user@host:port
/// format and launches an SSH session in the native terminal.

import SwiftUI

struct QuickConnectView: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var hostString = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Quick Connect")
                .font(.headline)

            Text("Enter a hostname to open an SSH session.")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("user@hostname:port", text: $hostString)
                .textFieldStyle(.roundedBorder)
                .onSubmit { connect() }

            Text("Examples: server.example.com, admin@192.168.1.1, root@host:2222")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func connect() {
        let raw = hostString.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        store.quickConnect(raw: raw)
        dismiss()
    }
}
