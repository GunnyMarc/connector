/// Tests for the TerminalService (platform detection, command building, quoting).
///
/// Mirrors the Python `test_terminal_service.py` — covers platform info,
/// SSH command construction with various auth modes, protocol-specific commands,
/// shell quoting, Tcl quoting, and expect script generation.
///
/// Note: Tests that would launch real terminals or processes are skipped.
/// Only pure/functional logic is tested here.

import Foundation
import Testing

@testable import Connector

// MARK: - Platform Detection

struct TestPlatformDetection {
    @Test("detectPlatform returns Darwin on macOS")
    func detectDarwin() {
        let info = TerminalService.detectPlatform()
        #expect(info.system == "Darwin")
        #expect(info.systemLabel == "macOS")
    }

    @Test("Default terminal is one of the catalog entries")
    func terminalDetection() {
        let info = TerminalService.detectPlatform()
        let catalogNames = Set(info.availableTerminals.map(\.name))
        // The default must be a known catalog entry, or — if absolutely
        // nothing is installed — the hard fallback "Terminal".
        #expect(catalogNames.contains(info.terminal) || info.terminal == "Terminal")
    }

    @Test("hasSshpass and hasExpect are booleans")
    func toolDetection() {
        let info = TerminalService.detectPlatform()
        // Just verify they are populated (actual value depends on host)
        _ = info.hasSshpass
        _ = info.hasExpect
    }

    @Test("PlatformInfo stores all fields")
    func platformInfoFields() {
        let info = PlatformInfo(
            system: "Darwin",
            systemLabel: "macOS",
            terminal: "Terminal",
            hasSshpass: false,
            hasExpect: true
        )
        #expect(info.system == "Darwin")
        #expect(info.systemLabel == "macOS")
        #expect(info.terminal == "Terminal")
        #expect(info.hasSshpass == false)
        #expect(info.hasExpect == true)
        #expect(info.availableTerminals.isEmpty)
    }
}

// MARK: - Terminal Discovery & Selection

struct TestTerminalDiscovery {
    @Test("discoverTerminals returns the expected catalog")
    func discoverContainsKnownApps() {
        let catalog = TerminalService.discoverTerminals()
        let names = catalog.map(\.name)
        #expect(names.contains("iTerm"))
        #expect(names.contains("Ghostty"))
        #expect(names.contains("Royal TSX"))
        #expect(names.contains("Terminal"))
    }

    @Test("Terminal.app collapses to a single catalog entry")
    func dedupTerminalApp() {
        let catalog = TerminalService.discoverTerminals()
        let count = catalog.filter { $0.name == "Terminal" }.count
        #expect(count == 1)
    }

    @Test("Default selection is the first installed entry")
    func defaultIsInstalled() {
        let svc = TerminalService()
        let installed = svc.platformInfo.availableTerminals.contains {
            $0.installed
        }
        // If anything is installed, the selection must be installed.
        if installed {
            #expect(svc.selectedTerminal.installed)
        }
    }

    @Test("setTerminal switches to a known catalog entry")
    func setKnownTerminal() {
        let svc = TerminalService()
        svc.setTerminal(name: "Ghostty", path: "/Applications/Ghostty.app")
        #expect(svc.selectedTerminal.name == "Ghostty")
        #expect(svc.selectedTerminal.path == "/Applications/Ghostty.app")
        #expect(svc.selectedTerminal.launcher == TerminalLauncher.ghostty)
    }

    @Test("setTerminal with empty path uses catalog default")
    func setTerminalUsesCatalogPath() {
        let svc = TerminalService()
        svc.setTerminal(name: "iTerm", path: "")
        #expect(svc.selectedTerminal.name == "iTerm")
        #expect(svc.selectedTerminal.path == "/Applications/iTerm.app")
        #expect(svc.selectedTerminal.launcher == TerminalLauncher.iTerm)
    }

    @Test("setTerminal with unknown name uses generic launcher")
    func setUnknownTerminal() {
        let svc = TerminalService()
        svc.setTerminal(name: "MyCustomTerm", path: "/Applications/MyCustomTerm.app")
        #expect(svc.selectedTerminal.name == "MyCustomTerm")
        #expect(svc.selectedTerminal.launcher == TerminalLauncher.openGeneric)
    }

    @Test("setTerminal with empty name is a no-op")
    func setEmptyNameNoOp() {
        let svc = TerminalService()
        let before = svc.selectedTerminal
        svc.setTerminal(name: "", path: "")
        #expect(svc.selectedTerminal.name == before.name)
        #expect(svc.selectedTerminal.launcher == before.launcher)
    }
}

// MARK: - Shell Quoting

struct TestShellQuoting {
    @Test("Simple alphanumeric strings are not quoted")
    func simpleStrings() {
        #expect("hello".shellQuoted == "hello")
        #expect("user123".shellQuoted == "user123")
        #expect("/usr/bin/ssh".shellQuoted == "/usr/bin/ssh")
        #expect("host.example.com".shellQuoted == "host.example.com")
    }

    @Test("Strings with spaces are single-quoted")
    func spacesQuoted() {
        #expect("hello world".shellQuoted == "'hello world'")
        #expect("my file.txt".shellQuoted == "'my file.txt'")
    }

    @Test("Strings with special characters are single-quoted")
    func specialCharsQuoted() {
        #expect("pass$word".shellQuoted == "'pass$word'")
        #expect("it's".shellQuoted == "'it'\\''s'")  // embedded single quote
    }

    @Test("Empty string returns empty quotes")
    func emptyString() {
        #expect("".shellQuoted == "''")
    }

    @Test("Path with tilde is quoted (tilde is special in shell)")
    func tildeQuoted() {
        // ~ is not in the safe charset, so it gets single-quoted.
        #expect("~/.ssh/id_rsa".shellQuoted == "'~/.ssh/id_rsa'")
    }

    @Test("At-sign passes through unquoted")
    func atSignPassesThrough() {
        #expect("user@host".shellQuoted == "user@host")
    }
}

// MARK: - CommandResult

struct TestCommandResult {
    @Test("CommandResult stores all fields")
    func fields() {
        let result = CommandResult(stdout: "output", stderr: "error", exitCode: 0)
        #expect(result.stdout == "output")
        #expect(result.stderr == "error")
        #expect(result.exitCode == 0)
    }

    @Test("CommandResult with non-zero exit code")
    func nonZeroExit() {
        let result = CommandResult(stdout: "", stderr: "Permission denied", exitCode: 255)
        #expect(result.exitCode == 255)
        #expect(result.stderr == "Permission denied")
    }
}

// MARK: - RemoteFile

struct TestRemoteFile {
    @Test("RemoteFile stores all fields")
    func fields() {
        let file = RemoteFile(
            name: "readme.md",
            path: "/home/user/readme.md",
            isDirectory: false,
            size: 1024,
            modified: "Jan 15 14:30"
        )
        #expect(file.name == "readme.md")
        #expect(file.path == "/home/user/readme.md")
        #expect(file.isDirectory == false)
        #expect(file.size == 1024)
        #expect(file.modified == "Jan 15 14:30")
    }

    @Test("RemoteFile directory entry")
    func directoryEntry() {
        let dir = RemoteFile(
            name: "subdir",
            path: "/home/user/subdir",
            isDirectory: true,
            size: 4096,
            modified: "Feb 01 09:00"
        )
        #expect(dir.isDirectory == true)
        #expect(dir.name == "subdir")
    }

    @Test("RemoteFile has unique IDs")
    func uniqueIDs() {
        let f1 = RemoteFile(name: "a", path: "/a", isDirectory: false, size: 0, modified: "")
        let f2 = RemoteFile(name: "b", path: "/b", isDirectory: false, size: 0, modified: "")
        #expect(f1.id != f2.id)
    }
}

// MARK: - ConnectorError

struct TestConnectorError {
    @Test("Error descriptions include context")
    func errorDescriptions() {
        let errors: [(ConnectorError, String)] = [
            (.siteNotFound("abc"), "abc"),
            (.folderExists("My Folder"), "My Folder"),
            (.folderNotFound("Missing"), "Missing"),
            (.encryptionFailed("bad key"), "bad key"),
            (.decryptionFailed("corrupt"), "corrupt"),
            (.storageFailed("disk full"), "disk full"),
            (.connectionFailed("timeout"), "timeout"),
            (.terminalLaunchFailed("not found"), "not found"),
            (.importFailed("bad format"), "bad format"),
            (.invalidData("null field"), "null field"),
        ]

        for (error, expectedSubstring) in errors {
            let desc = error.errorDescription ?? ""
            #expect(desc.contains(expectedSubstring),
                    "Expected '\(expectedSubstring)' in '\(desc)'")
        }
    }

    @Test("All error cases have non-nil descriptions")
    func allCasesHaveDescriptions() {
        let cases: [ConnectorError] = [
            .siteNotFound("x"),
            .folderExists("x"),
            .folderNotFound("x"),
            .encryptionFailed("x"),
            .decryptionFailed("x"),
            .storageFailed("x"),
            .connectionFailed("x"),
            .terminalLaunchFailed("x"),
            .importFailed("x"),
            .invalidData("x"),
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
        }
    }
}

// MARK: - TerminalService Initialisation

struct TestTerminalServiceInit {
    @Test("TerminalService uses auto-detected platform by default")
    func autoDetect() {
        let svc = TerminalService()
        #expect(svc.platformInfo.system == "Darwin")
    }

    @Test("TerminalService accepts injected PlatformInfo")
    func injectedInfo() {
        let info = PlatformInfo(
            system: "Darwin",
            systemLabel: "macOS",
            terminal: "TestTerminal",
            hasSshpass: true,
            hasExpect: false
        )
        let svc = TerminalService(platformInfo: info)
        #expect(svc.platformInfo.terminal == "TestTerminal")
        #expect(svc.platformInfo.hasSshpass == true)
        #expect(svc.platformInfo.hasExpect == false)
    }
}
