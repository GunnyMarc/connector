/// Terminal detection and native terminal launcher for connections.
///
/// Detects the macOS terminal application (iTerm or Terminal.app) and
/// provides methods to launch interactive sessions via AppleScript and
/// perform SFTP operations via `ssh`/`scp` subprocesses.
///
/// For password-based SSH/SCP, uses OpenSSH's SSH_ASKPASS mechanism
/// (built into macOS, no extra tools needed). Falls back to `sshpass`
/// if available.
///
/// Mirrors the Python `TerminalService` class, simplified for macOS-only.

import Foundation

// MARK: - Data Types

/// Result of a remote SSH command execution.
struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// A file or directory entry from an SFTP listing.
struct RemoteFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: String
}

/// One entry in the platform's terminal-application catalog.
///
/// `installed` reflects whether the bundle exists at `path` on the host;
/// `launcher` is the strategy id used by `launchInTerminal` to open
/// commands in that terminal.
struct TerminalApp: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(launcher)" }
    let name: String         // Human-readable label shown in the picker
    let path: String         // .app bundle path
    let launcher: String     // Launcher strategy id (see TerminalLauncher)
    let installed: Bool      // True if `path` exists at detection time
}

/// Snapshot of the detected terminal environment.
struct PlatformInfo: Sendable {
    let system: String                       // Always "Darwin"
    let systemLabel: String                  // Always "macOS"
    let terminal: String                     // Default terminal name at startup
    let hasSshpass: Bool                     // Whether sshpass is on PATH
    let hasExpect: Bool                      // Whether expect is on PATH
    let availableTerminals: [TerminalApp]    // Catalog with `installed` flags

    /// Convenience initialiser that fills in an empty catalog (used by tests).
    init(
        system: String,
        systemLabel: String,
        terminal: String,
        hasSshpass: Bool,
        hasExpect: Bool,
        availableTerminals: [TerminalApp] = []
    ) {
        self.system = system
        self.systemLabel = systemLabel
        self.terminal = terminal
        self.hasSshpass = hasSshpass
        self.hasExpect = hasExpect
        self.availableTerminals = availableTerminals
    }
}

/// Launcher strategy ids understood by `launchInTerminal`.
enum TerminalLauncher {
    static let appleTerminal = "macos_terminal"
    static let iTerm         = "macos_iterm"
    static let ghostty       = "macos_ghostty"
    static let openGeneric   = "macos_open"
}

/// Catalog of terminal applications Connector knows how to launch.
///
/// Order matters — the first installed entry becomes the auto-detect default.
/// To add a terminal, append an entry here and (if it needs a custom launch
/// strategy) register one in `launchInTerminal`.
private let macTerminalCatalog: [(name: String, path: String, launcher: String)] = [
    ("iTerm",      "/Applications/iTerm.app",                              TerminalLauncher.iTerm),
    ("Ghostty",    "/Applications/Ghostty.app",                            TerminalLauncher.ghostty),
    ("Royal TSX",  "/Applications/Royal TSX.app",                          TerminalLauncher.openGeneric),
    ("Alacritty",  "/Applications/Alacritty.app",                          TerminalLauncher.openGeneric),
    ("Kitty",      "/Applications/kitty.app",                              TerminalLauncher.openGeneric),
    ("WezTerm",    "/Applications/WezTerm.app",                            TerminalLauncher.openGeneric),
    ("Hyper",      "/Applications/Hyper.app",                              TerminalLauncher.openGeneric),
    ("Terminal",   "/System/Applications/Utilities/Terminal.app",          TerminalLauncher.appleTerminal),
    ("Terminal",   "/Applications/Utilities/Terminal.app",                 TerminalLauncher.appleTerminal),
]

// MARK: - Terminal Service

/// Launch sessions in the host's native terminal application.
///
/// `@unchecked Sendable`: the `selectedTerminal` is mutated only from the
/// main actor (Settings save / app init) while reads happen elsewhere; the
/// catalog inside `platformInfo` is immutable.
final class TerminalService: @unchecked Sendable {
    let platformInfo: PlatformInfo

    /// The terminal currently used to open new sessions. Defaults to the
    /// first installed entry from the catalog; user-overridable via
    /// `setTerminal(name:path:)`.
    private(set) var selectedTerminal: TerminalApp

    init(platformInfo: PlatformInfo? = nil) {
        let info = platformInfo ?? Self.detectPlatform()
        self.platformInfo = info
        self.selectedTerminal = Self.pickDefault(from: info.availableTerminals)
    }

    // MARK: - Platform Detection

    /// Probe the host and locate the default terminal application.
    static func detectPlatform() -> PlatformInfo {
        let catalog = Self.discoverTerminals()
        let defaultTerm = Self.pickDefault(from: catalog)

        let hasSshpass = Self.which("sshpass") != nil
        let hasExpect = Self.which("expect") != nil

        return PlatformInfo(
            system: "Darwin",
            systemLabel: "macOS",
            terminal: defaultTerm.name,
            hasSshpass: hasSshpass,
            hasExpect: hasExpect,
            availableTerminals: catalog
        )
    }

    /// Build the deduplicated catalog of terminals known to Connector,
    /// flagging which ones are actually installed on this Mac.
    static func discoverTerminals() -> [TerminalApp] {
        let fm = FileManager.default
        var byKey: [String: TerminalApp] = [:]
        var order: [String] = []

        for entry in macTerminalCatalog {
            let installed = fm.fileExists(atPath: entry.path)
            // Dedup on (name, launcher) so Terminal.app's two possible
            // locations collapse to one entry.
            let key = "\(entry.name)|\(entry.launcher)"
            if let existing = byKey[key] {
                // Prefer the path that actually exists.
                if installed && !existing.installed {
                    byKey[key] = TerminalApp(
                        name: entry.name,
                        path: entry.path,
                        launcher: entry.launcher,
                        installed: true
                    )
                }
            } else {
                byKey[key] = TerminalApp(
                    name: entry.name,
                    path: entry.path,
                    launcher: entry.launcher,
                    installed: installed
                )
                order.append(key)
            }
        }

        return order.compactMap { byKey[$0] }
    }

    /// Return the first installed catalog entry, or a hard fallback.
    private static func pickDefault(from catalog: [TerminalApp]) -> TerminalApp {
        if let first = catalog.first(where: { $0.installed }) {
            return first
        }
        return TerminalApp(
            name: "Terminal",
            path: "/System/Applications/Utilities/Terminal.app",
            launcher: TerminalLauncher.appleTerminal,
            installed: false
        )
    }

    // MARK: - Selection

    /// Apply a user-selected terminal. Empty `name` is a no-op (caller can
    /// pass empty strings to mean "keep the auto-detect default").
    ///
    /// When `path` is empty, the catalog's default path for *name* is used.
    /// Names that aren't in the catalog fall back to the generic
    /// `open -na <path> --args -e <command>` launcher.
    func setTerminal(name: String, path: String = "") {
        guard !name.isEmpty else { return }

        // Try to match the catalog by name to inherit its launcher + default
        // path. Match against the discovered catalog first (so installed-flag
        // and exact path stay in sync), then fall back to the static catalog.
        if let match = platformInfo.availableTerminals.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            selectedTerminal = TerminalApp(
                name: match.name,
                path: path.isEmpty ? match.path : path,
                launcher: match.launcher,
                installed: match.installed
            )
            return
        }

        // User-supplied name that isn't in the catalog: route through the
        // generic macOS launcher.
        selectedTerminal = TerminalApp(
            name: name,
            path: path.isEmpty ? name : path,
            launcher: TerminalLauncher.openGeneric,
            installed: !path.isEmpty && FileManager.default.fileExists(atPath: path)
        )
    }

    /// Check if an executable exists on PATH.
    private static func which(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}

        return nil
    }

    // MARK: - Session Launcher

    /// Open an interactive session in the native terminal.
    ///
    /// Dispatches to the correct command builder based on the site's protocol.
    func launchSession(site: Site) throws {
        let cmd = try buildCommandForProtocol(site: site)
        try launchInTerminal(cmd)
    }

    /// Open an interactive SSH session (quick-connect style).
    func launchSSH(
        hostname: String,
        port: Int,
        username: String,
        keyPath: String = "",
        password: String = ""
    ) throws {
        let cmd = try buildSSHCommand(
            hostname: hostname,
            port: port,
            username: username,
            keyPath: keyPath,
            password: password
        )
        try launchInTerminal(cmd)
    }

    // MARK: - Protocol Command Builders

    /// Return the shell command string for the given site's protocol.
    private func buildCommandForProtocol(site: Site) throws -> String {
        switch site.connectionProtocol {
        case .ssh2, .ssh1:
            return try buildSSHCommand(
                hostname: site.hostname,
                port: site.port,
                username: site.username,
                keyPath: site.authType == .key ? site.keyPath : "",
                password: site.authType == .password ? site.password : "",
                sshVersion: site.connectionProtocol == .ssh1 ? 1 : 2
            )
        case .local:
            return buildLocalCommand()
        case .raw:
            return buildRawCommand(hostname: site.hostname, port: site.port)
        case .telnet:
            return buildTelnetCommand(hostname: site.hostname, port: site.port, username: site.username)
        case .serial:
            return buildSerialCommand(serialPort: site.serialPort, serialBaud: site.serialBaud)
        }
    }

    private func buildLocalCommand() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        return "\(shell.shellQuoted) --login"
    }

    private func buildRawCommand(hostname: String, port: Int) -> String {
        ["nc", hostname, String(port)].map(\.shellQuoted).joined(separator: " ")
    }

    private func buildTelnetCommand(hostname: String, port: Int, username: String) -> String {
        var parts = ["telnet"]
        if !username.isEmpty {
            parts += ["-l", username]
        }
        parts.append(hostname)
        if port != 23 {
            parts.append(String(port))
        }
        return parts.map(\.shellQuoted).joined(separator: " ")
    }

    private func buildSerialCommand(serialPort: String, serialBaud: Int) -> String {
        let portPath = serialPort.isEmpty ? "/dev/ttyUSB0" : serialPort
        return ["screen", portPath, String(serialBaud)].map(\.shellQuoted).joined(separator: " ")
    }

    /// Build SSH command arguments as an array (no shell quoting).
    private func buildSSHArgsArray(
        hostname: String,
        port: Int,
        username: String,
        keyPath: String = "",
        isPasswordAuth: Bool = false,
        sshVersion: Int = 2
    ) -> [String] {
        var args = ["ssh", "-o", "StrictHostKeyChecking=no"]
        if sshVersion == 1 {
            args += ["-o", "Protocol=1"]
        }
        if !keyPath.isEmpty {
            let expanded = NSString(string: keyPath).expandingTildeInPath
            args += ["-i", expanded]
        }
        if isPasswordAuth {
            // Disable pubkey to avoid "Too many authentication failures"
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }
        if port != 22 {
            args += ["-p", String(port)]
        }
        if !username.isEmpty {
            args.append("\(username)@\(hostname)")
        } else {
            args.append(hostname)
        }
        return args
    }

    /// Build the terminal command for an SSH session, with password automation.
    ///
    /// Password handling priority:
    ///   1. `sshpass` (if installed) — most reliable
    ///   2. `expect` (built into macOS) — writes a temp script for auto-login
    ///   3. Plain `ssh` — user enters password manually
    private func buildSSHCommand(
        hostname: String,
        port: Int,
        username: String,
        keyPath: String = "",
        password: String = "",
        sshVersion: Int = 2
    ) throws -> String {
        let isPasswordAuth = !password.isEmpty && keyPath.isEmpty
        let args = buildSSHArgsArray(
            hostname: hostname,
            port: port,
            username: username,
            keyPath: keyPath,
            isPasswordAuth: isPasswordAuth,
            sshVersion: sshVersion
        )
        let sshCmd = args.map(\.shellQuoted).joined(separator: " ")

        guard !password.isEmpty else { return sshCmd }

        // 1. Prefer sshpass if available.
        if platformInfo.hasSshpass {
            let safePw = password.shellQuoted
            return "export SSHPASS=\(safePw); sshpass -e \(sshCmd); unset SSHPASS"
        }

        // 2. Use expect to auto-fill the password in the terminal.
        if platformInfo.hasExpect {
            let scriptURL = try createExpectLoginScript(sshArgs: args, password: password)
            return "\(scriptURL.path.shellQuoted); rm -f \(scriptURL.path.shellQuoted)"
        }

        // 3. No helper available — plain ssh (user enters password manually).
        return sshCmd
    }

    // MARK: - Expect Script for Interactive Password Auth

    /// Create a temporary `expect` script for automated SSH password login.
    ///
    /// The script spawns the SSH session, waits for a password/passphrase
    /// prompt, sends the stored password, then hands control to the user
    /// via `interact`. The terminal command arranges for the script to be
    /// deleted after the session ends.
    private func createExpectLoginScript(sshArgs: [String], password: String) throws -> URL {
        let fm = FileManager.default
        let scriptURL = fm.temporaryDirectory.appendingPathComponent(
            "connector_\(UUID().uuidString).exp"
        )

        let spawnLine = "spawn " + sshArgs.map { tclQuote($0) }.joined(separator: " ")
        let tclPassword = tclEscapeForDoubleQuotes(password)

        let script = """
        #!/usr/bin/expect -f
        set timeout 30
        \(spawnLine)
        expect {
            -re {[Pp]ass(word|phrase)} {
                send "\(tclPassword)\\r"
                interact
            }
            timeout {
                puts "\\nConnection timed out."
                exit 1
            }
            eof {
                puts "\\nConnection closed."
                exit 1
            }
        }
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Quote a string for use as a Tcl word argument.
    ///
    /// Uses braces for strings containing spaces or special characters,
    /// falling back to double-quote escaping when braces can't be used.
    private func tclQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.=@:/,+"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        if !s.contains("{") && !s.contains("}") {
            return "{\(s)}"
        }
        return "\"\(tclEscapeForDoubleQuotes(s))\""
    }

    /// Escape a string for use inside Tcl double quotes.
    private func tclEscapeForDoubleQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    // MARK: - macOS Terminal Launcher

    /// Launch a command in the user-selected terminal.
    ///
    /// Dispatches to one of several strategies based on
    /// `selectedTerminal.launcher`. AppleScript is used for Terminal.app
    /// and iTerm; everything else goes through `open -na <bundle> --args`.
    private func launchInTerminal(_ cmd: String) throws {
        switch selectedTerminal.launcher {
        case TerminalLauncher.iTerm:
            try launchITerm(cmd)
        case TerminalLauncher.appleTerminal:
            try launchAppleTerminal(cmd)
        case TerminalLauncher.ghostty:
            try launchViaOpen(cmd)
        case TerminalLauncher.openGeneric:
            try launchViaOpen(cmd)
        default:
            try launchAppleTerminal(cmd)
        }
    }

    private func launchAppleTerminal(_ cmd: String) throws {
        let safeCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(safeCmd)"
        end tell
        """
        try runOSAScript(script)
    }

    private func launchITerm(_ cmd: String) throws {
        let safeCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm"
            activate
            create window with default profile command "\(safeCmd)"
        end tell
        """
        try runOSAScript(script)
    }

    /// Launch a command in any third-party terminal that supports `-e <cmd>`
    /// (Ghostty, Royal TSX, Alacritty, Kitty, WezTerm, Hyper, …) via
    /// `open -na <bundle> --args -e <cmd>`.
    private func launchViaOpen(_ cmd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", selectedTerminal.path, "--args", "-e", cmd]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConnectorError.terminalLaunchFailed(
                "\(selectedTerminal.name) not found at \(selectedTerminal.path): \(error.localizedDescription)"
            )
        }
    }

    /// Run an AppleScript string via /usr/bin/osascript.
    private func runOSAScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConnectorError.terminalLaunchFailed(
                "\(selectedTerminal.name) not found: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - SSH_ASKPASS Helper

    /// Create a temporary askpass script that echoes the given password.
    ///
    /// OpenSSH's `SSH_ASKPASS` mechanism calls this script to obtain the
    /// password non-interactively. This is built into macOS's `ssh` and
    /// `scp` — no extra tools like `sshpass` are needed.
    ///
    /// Returns the URL to the temporary script. The caller must delete it
    /// when done.
    private func createAskpassScript(password: String) throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("connector_askpass_\(UUID().uuidString).sh")

        // Escape single quotes in the password for the shell script.
        let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\necho '\(escapedPassword)'\n"

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        return scriptURL
    }

    /// Configure a Process's environment for SSH_ASKPASS-based password auth.
    ///
    /// Sets SSH_ASKPASS, SSH_ASKPASS_REQUIRE=force, and DISPLAY so that
    /// ssh/scp call the askpass script instead of prompting on a terminal.
    private func configurePasswordEnvironment(
        process: Process,
        password: String,
        askpassURL: URL
    ) {
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpassURL.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        process.environment = env
    }

    // MARK: - SSH options for password auth

    /// SSH options that force password-only auth and skip key attempts.
    ///
    /// Without these, ssh tries every key in ~/.ssh/ first, each counting
    /// as a failed attempt. After enough failures the server disconnects
    /// with "Too many authentication failures".
    private static let passwordAuthSSHOptions: [String] = [
        "-o", "PubkeyAuthentication=no",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
    ]

    /// SCP options equivalent (same flags, SCP uses them too).
    private static let passwordAuthSCPOptions: [String] = [
        "-o", "PubkeyAuthentication=no",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
    ]

    // MARK: - SFTP Operations via SSH Subprocess

    /// List remote directory contents by running `ls -la` over SSH.
    ///
    /// This method runs synchronously and should be called off the main actor.
    func sftpList(site: Site, remotePath: String) throws -> [RemoteFile] {
        let path = remotePath.isEmpty ? "." : remotePath

        // Use ls -la to get file listings over SSH
        let result = try executeSSHCommand(site: site, command: "ls -la \(path.shellQuoted)")

        guard result.exitCode == 0 else {
            throw ConnectorError.connectionFailed(result.stderr.isEmpty ? "ls command failed" : result.stderr)
        }

        return parseLsOutput(result.stdout, basePath: path)
    }

    /// Resolve a remote path to its canonical absolute form.
    func sftpNormalize(site: Site, remotePath: String) throws -> String {
        let path = remotePath.isEmpty ? "." : remotePath
        let result = try executeSSHCommand(
            site: site,
            command: "cd \(path.shellQuoted) && pwd"
        )

        guard result.exitCode == 0 else {
            throw ConnectorError.connectionFailed(result.stderr)
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Download a remote file using `scp`.
    func sftpDownload(site: Site, remotePath: String, localPath: String) throws {
        var args = buildSCPArgs(site: site, recursive: false)
        args.append(buildSCPRemote(site: site, remotePath: remotePath))
        args.append(localPath)
        try executeSCP(site: site, scpArgs: args)
    }

    /// Upload a local file using `scp`.
    func sftpUpload(site: Site, localPath: String, remotePath: String) throws {
        var args = buildSCPArgs(site: site, recursive: false)
        args.append(localPath)
        args.append(buildSCPRemote(site: site, remotePath: remotePath))
        try executeSCP(site: site, scpArgs: args)
    }

    /// Download a remote directory recursively using `scp -r`.
    ///
    /// Copies the entire directory tree, including hidden files and
    /// all subdirectories, to the local destination.
    func sftpDownloadDirectory(site: Site, remotePath: String, localPath: String) throws {
        var args = buildSCPArgs(site: site, recursive: true)
        args.append(buildSCPRemote(site: site, remotePath: remotePath))
        args.append(localPath)
        try executeSCP(site: site, scpArgs: args)
    }

    /// Upload a local directory recursively using `scp -r`.
    ///
    /// Copies the entire directory tree, including hidden files and
    /// all subdirectories, to the remote destination.
    func sftpUploadDirectory(site: Site, localPath: String, remotePath: String) throws {
        var args = buildSCPArgs(site: site, recursive: true)
        args.append(localPath)
        args.append(buildSCPRemote(site: site, remotePath: remotePath))
        try executeSCP(site: site, scpArgs: args)
    }

    /// Delete a remote file via `rm` over SSH.
    func sftpDelete(site: Site, remotePath: String) throws {
        let result = try executeSSHCommand(
            site: site,
            command: "rm \(remotePath.shellQuoted)",
        )
        guard result.exitCode == 0 else {
            throw ConnectorError.connectionFailed(
                result.stderr.isEmpty ? "Delete failed" : result.stderr
            )
        }
    }

    /// Delete a remote directory recursively via `rm -rf` over SSH.
    ///
    /// Removes the directory and all of its contents. This operation
    /// is irreversible — callers should confirm with the user first.
    func sftpDeleteDirectory(site: Site, remotePath: String) throws {
        let result = try executeSSHCommand(
            site: site,
            command: "rm -rf \(remotePath.shellQuoted)",
        )
        guard result.exitCode == 0 else {
            throw ConnectorError.connectionFailed(
                result.stderr.isEmpty ? "Directory delete failed" : result.stderr
            )
        }
    }

    // MARK: - SCP Subprocess Helpers

    /// Build common SCP arguments for the given site.
    ///
    /// Includes host-key checking, timeout, auth options, port, and key path.
    /// Pass `recursive: true` to add the `-r` flag for directory transfers.
    private func buildSCPArgs(site: Site, recursive: Bool) -> [String] {
        var args: [String] = []
        if recursive {
            args.append("-r")
        }
        args += ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10"]

        let isPasswordAuth = site.authType == .password && !site.password.isEmpty
        if isPasswordAuth {
            args += Self.passwordAuthSCPOptions
        }
        if site.port != 22 {
            args += ["-P", String(site.port)]
        }
        if site.authType == .key && !site.keyPath.isEmpty {
            args += ["-i", NSString(string: site.keyPath).expandingTildeInPath]
        }

        return args
    }

    /// Build the remote path specification for SCP (`user@host:path`).
    private func buildSCPRemote(site: Site, remotePath: String) -> String {
        if !site.username.isEmpty {
            "\(site.username)@\(site.hostname):\(remotePath)"
        } else {
            "\(site.hostname):\(remotePath)"
        }
    }

    /// Execute an SCP transfer with the given arguments.
    ///
    /// Handles password authentication via `sshpass` (if available) or
    /// the SSH_ASKPASS mechanism (built into macOS OpenSSH).
    private func executeSCP(site: Site, scpArgs: [String]) throws {
        let process = Process()
        var askpassURL: URL?
        let isPasswordAuth = site.authType == .password && !site.password.isEmpty

        if isPasswordAuth {
            if platformInfo.hasSshpass {
                var env = ProcessInfo.processInfo.environment
                env["SSHPASS"] = site.password
                process.environment = env
                process.executableURL = URL(
                    fileURLWithPath: Self.which("sshpass") ?? "/usr/local/bin/sshpass"
                )
                process.arguments = ["-e", "scp"] + scpArgs
            } else {
                // Use SSH_ASKPASS (built into macOS OpenSSH)
                let scriptURL = try createAskpassScript(password: site.password)
                askpassURL = scriptURL
                configurePasswordEnvironment(
                    process: process,
                    password: site.password,
                    askpassURL: scriptURL,
                )
                process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
                process.arguments = scpArgs
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = scpArgs
        }

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        // Detach from controlling terminal so SSH_ASKPASS is used.
        process.standardInput = FileHandle.nullDevice

        defer { if let url = askpassURL { try? FileManager.default.removeItem(at: url) } }

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Transfer failed"
            throw ConnectorError.connectionFailed(
                errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - SSH Command Execution

    /// Execute a command on a remote host via `ssh` subprocess.
    func executeSSHCommand(site: Site, command: String) throws -> CommandResult {
        var args = ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10"]

        let isPasswordAuth = site.authType == .password && !site.password.isEmpty

        // When using password auth, skip pubkey attempts to avoid
        // "Too many authentication failures".
        if isPasswordAuth {
            args += Self.passwordAuthSSHOptions
        }

        if site.authType == .key && !site.keyPath.isEmpty {
            args += ["-i", NSString(string: site.keyPath).expandingTildeInPath]
        }
        if site.port != 22 {
            args += ["-p", String(site.port)]
        }
        if !site.username.isEmpty {
            args.append("\(site.username)@\(site.hostname)")
        } else {
            args.append(site.hostname)
        }
        args.append(command)

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        var askpassURL: URL?

        if isPasswordAuth {
            if platformInfo.hasSshpass {
                // Prefer sshpass if installed
                var env = ProcessInfo.processInfo.environment
                env["SSHPASS"] = site.password
                process.environment = env
                process.executableURL = URL(fileURLWithPath: Self.which("sshpass") ?? "/usr/local/bin/sshpass")
                process.arguments = ["-e", "ssh"] + args
            } else {
                // Use SSH_ASKPASS — built into macOS OpenSSH, no extra tools.
                // Creates a temp script that echoes the password, tells ssh
                // to call it via SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force.
                let scriptURL = try createAskpassScript(password: site.password)
                askpassURL = scriptURL
                configurePasswordEnvironment(process: process, password: site.password, askpassURL: scriptURL)
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = args
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
        }

        process.standardOutput = outPipe
        process.standardError = errPipe
        // Detach stdin so ssh has no controlling terminal and uses SSH_ASKPASS.
        process.standardInput = FileHandle.nullDevice

        // Clean up the temp askpass script after the process finishes.
        defer { if let url = askpassURL { try? FileManager.default.removeItem(at: url) } }

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    // MARK: - Parsing Helpers

    /// Parse `ls -la` output into `RemoteFile` entries.
    private func parseLsOutput(_ output: String, basePath: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and the "total" line
            guard !trimmed.isEmpty, !trimmed.hasPrefix("total ") else { continue }

            // Parse: permissions links owner group size month day time/year name
            let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }

            let permissions = parts[0]
            let name = parts[8]

            // Skip . and ..
            guard name != "." && name != ".." else { continue }

            let isDir = permissions.hasPrefix("d")
            let size = Int64(parts[4]) ?? 0
            let modified = "\(parts[5]) \(parts[6]) \(parts[7])"

            let fullPath: String
            if basePath == "/" {
                fullPath = "/\(name)"
            } else {
                fullPath = "\(basePath)/\(name)"
            }

            files.append(RemoteFile(
                name: name,
                path: fullPath,
                isDirectory: isDir,
                size: size,
                modified: modified
            ))
        }

        // Directories first, then alphabetical
        files.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return files
    }
}

// MARK: - String Shell Quoting

extension String {
    /// Shell-quote a string for safe use in command arguments.
    var shellQuoted: String {
        if self.isEmpty { return "''" }
        // If the string contains no special characters, return as-is
        let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.=@:,"))
        if self.unicodeScalars.allSatisfy({ safeChars.contains($0) }) {
            return self
        }
        // Wrap in single quotes, escaping any existing single quotes
        return "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
