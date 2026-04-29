/// Application-level error types for the Connector app.

import Foundation

/// Errors raised by Connector services and view models.
enum ConnectorError: LocalizedError, Sendable {
    case siteNotFound(String)
    case folderExists(String)
    case folderNotFound(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case storageFailed(String)
    case connectionFailed(String)
    case terminalLaunchFailed(String)
    case importFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .siteNotFound(let id):
            "Site not found: \(id)"
        case .folderExists(let name):
            "Folder '\(name)' already exists."
        case .folderNotFound(let name):
            "Folder '\(name)' not found."
        case .encryptionFailed(let reason):
            "Encryption failed: \(reason)"
        case .decryptionFailed(let reason):
            "Decryption failed: \(reason)"
        case .storageFailed(let reason):
            "Storage error: \(reason)"
        case .connectionFailed(let reason):
            "Connection failed: \(reason)"
        case .terminalLaunchFailed(let reason):
            "Terminal launch failed: \(reason)"
        case .importFailed(let reason):
            "Import failed: \(reason)"
        case .invalidData(let reason):
            "Invalid data: \(reason)"
        }
    }
}
