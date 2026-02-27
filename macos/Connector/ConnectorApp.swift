/// Connector — macOS native SSH/SFTP connectivity manager.
///
/// Application entry point. Initialises encrypted storage services and
/// injects the observable stores into the SwiftUI environment.

import SwiftUI

@main
struct ConnectorApp: App {
    // MARK: - Service Setup

    /// Data directory: ~/Library/Application Support/Connector/
    private static let dataDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Connector", isDirectory: true)
    }()

    private static let keyURL      = dataDir.appendingPathComponent(".key")
    private static let sitesURL    = dataDir.appendingPathComponent("sites.enc")
    private static let settingsURL = dataDir.appendingPathComponent("settings.enc")

    // Services (created once at launch)
    private let crypto: CryptoService
    private let storage: StorageService
    private let settingsService: SettingsService
    private let terminal: TerminalService

    // Observable stores
    @State private var siteStore: SiteStore
    @State private var settingsStore: SettingsStore

    init() {
        let crypto = CryptoService(keyURL: Self.keyURL)
        let storage = StorageService(fileURL: Self.sitesURL, crypto: crypto)
        let settingsService = SettingsService(fileURL: Self.settingsURL, crypto: crypto)
        let terminal = TerminalService()

        self.crypto = crypto
        self.storage = storage
        self.settingsService = settingsService
        self.terminal = terminal

        _siteStore = State(initialValue: SiteStore(
            storage: storage,
            settings: settingsService,
            terminal: terminal
        ))
        _settingsStore = State(initialValue: SettingsStore(service: settingsService))
    }

    // MARK: - App Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(siteStore)
                .environment(settingsStore)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Site") {
                    NotificationCenter.default.post(name: .newSiteRequested, object: nil)
                }
                .keyboardShortcut("n")

                Button("Quick Connect...") {
                    NotificationCenter.default.post(name: .quickConnectRequested, object: nil)
                }
                .keyboardShortcut("k")

                Divider()

                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshRequested, object: nil)
                }
                .keyboardShortcut("r")
            }
        }

        // SFTP browser (opened as a resizable window)
        WindowGroup("SFTP Browser", id: "sftp", for: String.self) { $siteID in
            Group {
                if let siteID,
                   let site = siteStore.sites.first(where: { $0.id == siteID })
                {
                    SFTPBrowserView(site: site)
                } else {
                    ContentUnavailableView(
                        "Site Not Found",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The requested site could not be found.")
                    )
                }
            }
            .environment(siteStore)
            .environment(settingsStore)
        }
        .defaultSize(width: 700, height: 500)

        // Settings window (Cmd+, from app menu)
        Settings {
            SettingsView()
                .environment(siteStore)
                .environment(settingsStore)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newSiteRequested = Notification.Name("newSiteRequested")
    static let quickConnectRequested = Notification.Name("quickConnectRequested")
    static let refreshRequested = Notification.Name("refreshRequested")
}
