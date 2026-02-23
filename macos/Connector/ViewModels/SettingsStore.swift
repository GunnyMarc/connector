/// Observable wrapper around SettingsService for SwiftUI bindings.

import Foundation
import Observation

/// Observable store for global application settings.
@Observable
final class SettingsStore {
    var settings: AppSettings = .defaults
    var errorMessage: String?

    private let service: SettingsService

    init(service: SettingsService) {
        self.service = service
        reload()
    }

    /// Reload settings from encrypted storage.
    func reload() {
        do {
            settings = try service.getAll()
        } catch {
            errorMessage = "Failed to load settings: \(error.localizedDescription)"
        }
    }

    /// Save current settings to encrypted storage.
    func save() {
        do {
            try service.save(settings)
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }
    }
}
