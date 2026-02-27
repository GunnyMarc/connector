/// Main content view with NavigationSplitView layout.
///
/// Two-column layout: sidebar (folders + sites) and detail (site info or form).
/// Mirrors the Python app's index.html + sidebar.

import Combine
import SwiftUI

/// Root layout view using a two-column NavigationSplitView.
struct ContentView: View {
    @Environment(SiteStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore

    @State private var showNewSiteForm = false
    @State private var showQuickConnect = false
    @State private var editingSite: Site?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                showNewSiteForm: $showNewSiteForm,
                showQuickConnect: $showQuickConnect,
                editingSite: $editingSite
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let site = store.selectedSite {
                SiteDetailView(
                    site: site,
                    editingSite: $editingSite
                )
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showNewSiteForm) {
            SiteFormView(site: nil)
        }
        .sheet(item: $editingSite) { site in
            SiteFormView(site: site)
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView()
        }
        .alert("Error", isPresented: .init(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .frame(minWidth: 700, minHeight: 450)
        // Handle menu bar commands via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .newSiteRequested)) { _ in
            showNewSiteForm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickConnectRequested)) { _ in
            showQuickConnect = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
            store.reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Connector")
                .font(.title)
            Text("Select a site from the sidebar or create a new one.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("New Site") { showNewSiteForm = true }
                Button("Quick Connect") { showQuickConnect = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
