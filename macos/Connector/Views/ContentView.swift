/// Main content view with NavigationSplitView layout.
///
/// Three-column layout: sidebar (folders + sites), detail (site info or form),
/// and optional inspector. Mirrors the Python app's index.html + sidebar.

import SwiftUI

/// Root layout view using a two-column NavigationSplitView.
struct ContentView: View {
    @Environment(SiteStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore

    @State private var showNewSiteForm = false
    @State private var showQuickConnect = false
    @State private var showSettings = false
    @State private var editingSite: Site?
    @State private var sftpSite: Site?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                showNewSiteForm: $showNewSiteForm,
                showQuickConnect: $showQuickConnect,
                showSettings: $showSettings,
                editingSite: $editingSite,
                sftpSite: $sftpSite
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let site = store.selectedSite {
                SiteDetailView(
                    site: site,
                    editingSite: $editingSite,
                    sftpSite: $sftpSite
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $sftpSite) { site in
            SFTPBrowserView(site: site)
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
