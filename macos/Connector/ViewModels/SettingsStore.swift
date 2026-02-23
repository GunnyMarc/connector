/// Observable wrapper around SettingsService for SwiftUI bindings.
///
/// Provides load, save, and reset-to-defaults for the global application
/// settings. After saving, notifies the SiteStore to reload so folder
/// changes propagate immediately.

import Foundation
import Observation

/// Observable store for global application settings.
@Observable
final class SettingsStore {
    var settings: AppSettings = .defaults
    var errorMessage: String?
    var savedSuccessfully: Bool = false

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
    /// Returns true on success.
    @discardableResult
    func save() -> Bool {
        do {
            try service.save(settings)
            savedSuccessfully = true
            return true
        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
            savedSuccessfully = false
            return false
        }
    }

    /// Reset all settings to factory defaults and persist.
    func resetToDefaults() {
        settings = .defaults
        save()
    }
}
