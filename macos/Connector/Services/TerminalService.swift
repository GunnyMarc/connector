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

/// Snapshot of the detected terminal environment.
struct PlatformInfo: Sendable {
    let system: String         // Always "Darwin"
    let systemLabel: String    // Always "macOS"
    let terminal: String       // "iTerm" or "Terminal"
    let hasSshpass: Bool       // Whether sshpass is on PATH
    let hasExpect: Bool        // Whether expect is on PATH
}

// MARK: - Terminal Service

/// Launch sessions in the host's native terminal application.
final class TerminalService: Sendable {
    let platformInfo: PlatformInfo

    init(platformInfo: PlatformInfo? = nil) {
        self.platformInfo = platformInfo ?? Self.detectPlatform()
    }

    // MARK: - Platform Detection

    /// Probe the host and locate the default terminal application.
    static func detectPlatform() -> PlatformInfo {
        let terminal: String
        let iTerm = "/Applications/iTerm.app"
        if FileManager.default.fileExists(atPath: iTerm) {
            terminal = "iTerm"
        } else {
            terminal = "Terminal"
        }

        let hasSshpass = Self.which("sshpass") != nil
        let hasExpect = Self.which("expect") != nil

        return PlatformInfo(
            system: "Darwin",
            systemLabel: "macOS",
            terminal: terminal,
            hasSshpass: hasSshpass,
            hasExpect: hasExpect
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

    /// Launch a command in the native macOS terminal via AppleScript.
    private func launchInTerminal(_ cmd: String) throws {
        let safeCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if platformInfo.terminal == "iTerm" {
            script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(safeCmd)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(safeCmd)"
            end tell
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ConnectorError.terminalLaunchFailed(
                "\(platformInfo.terminal) not found: \(error.localizedDescription)"
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

    // MARK: - SFTP Operations with Progress

    /// Callback signature for transfer progress updates.
    ///
    /// - Parameters:
    ///   - bytesTransferred: Cumulative bytes transferred so far.
    ///   - totalBytes: Total bytes to transfer.
    ///   - message: Verbose log message describing the current step.
    typealias TransferProgress = @Sendable (Int64, Int64, String) -> Void

    /// Return the total size in bytes of a remote path (file or directory).
    ///
    /// Uses `du -sb` (GNU coreutils) with a `stat` fallback for
    /// single files on BSD/macOS remotes.
    func sftpRemoteSize(site: Site, remotePath: String) throws -> Int64 {
        // Try GNU du first, fall back to BSD stat for single files.
        let cmd = """
        du -sb \(remotePath.shellQuoted) 2>/dev/null | head -1 | cut -f1 \
        || stat -f%z \(remotePath.shellQuoted) 2>/dev/null \
        || echo 0
        """
        let result = try executeSSHCommand(site: site, command: cmd)
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(raw) ?? 0
    }

    /// Recursively list all **files** under a remote directory with sizes.
    ///
    /// Returns flat list for progress tracking — each entry is a regular file.
    func sftpListFilesRecursive(
        site: Site,
        remotePath: String
    ) throws -> [(path: String, size: Int64)] {
        let cmd = "find \(remotePath.shellQuoted) -type f -exec stat -c '%s %n' {} + 2>/dev/null " +
                  "|| find \(remotePath.shellQuoted) -type f -exec stat -f '%z %N' {} +"
        let result = try executeSSHCommand(site: site, command: cmd)
        guard result.exitCode == 0 else { return [] }

        var entries: [(path: String, size: Int64)] = []
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Format: "size path"
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let sizeStr = String(trimmed[trimmed.startIndex..<spaceIdx])
            let path = String(trimmed[trimmed.index(after: spaceIdx)...])
            let size = Int64(sizeStr) ?? 0
            entries.append((path: path, size: size))
        }
        return entries
    }

    /// Download a single remote file using SCP, reporting byte-level progress
    /// by polling the growing local file size.
    func sftpDownloadWithProgress(
        site: Site,
        remotePath: String,
        localPath: String,
        totalSize: Int64,
        onProgress: TransferProgress
    ) throws {
        let filename = (remotePath as NSString).lastPathComponent
        onProgress(0, totalSize, "Downloading \(filename)...")

        // Ensure local file exists so we can stat it during transfer.
        FileManager.default.createFile(atPath: localPath, contents: nil)

        // Run SCP in a background thread.
        var scpError: Error?
        let scpDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var args = buildSCPArgs(site: site, recursive: false)
                args.append(buildSCPRemote(site: site, remotePath: remotePath))
                args.append(localPath)
                try executeSCP(site: site, scpArgs: args)
            } catch {
                scpError = error
            }
            scpDone.signal()
        }

        // Poll local file size until SCP finishes.
        while scpDone.wait(timeout: .now() + .milliseconds(300)) == .timedOut {
            let attrs = try? FileManager.default.attributesOfItem(atPath: localPath)
            let current = (attrs?[.size] as? Int64) ?? 0
            onProgress(min(current, totalSize), totalSize, "Downloading \(filename)...")
        }

        if let err = scpError { throw err }
        onProgress(totalSize, totalSize, "Downloaded \(filename)")
    }

    /// Upload a single local file using SCP, reporting progress by polling
    /// the remote file size via SSH.
    func sftpUploadWithProgress(
        site: Site,
        localPath: String,
        remotePath: String,
        totalSize: Int64,
        onProgress: TransferProgress
    ) throws {
        let filename = (localPath as NSString).lastPathComponent
        onProgress(0, totalSize, "Uploading \(filename)...")

        // Run SCP in a background thread.
        var scpError: Error?
        let scpDone = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var args = buildSCPArgs(site: site, recursive: false)
                args.append(localPath)
                args.append(buildSCPRemote(site: site, remotePath: remotePath))
                try executeSCP(site: site, scpArgs: args)
            } catch {
                scpError = error
            }
            scpDone.signal()
        }

        // Poll remote file size via SSH until SCP finishes.
        var lastPoll = Date.distantPast
        while scpDone.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            // Throttle remote stat calls to at most once per second.
            guard Date().timeIntervalSince(lastPoll) >= 1.0 else { continue }
            lastPoll = Date()

            let cmd = "stat -c%s \(remotePath.shellQuoted) 2>/dev/null " +
                      "|| stat -f%z \(remotePath.shellQuoted) 2>/dev/null " +
                      "|| echo 0"
            if let result = try? executeSSHCommand(site: site, command: cmd) {
                let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let current = Int64(raw) ?? 0
                onProgress(min(current, totalSize), totalSize, "Uploading \(filename)...")
            }
        }

        if let err = scpError { throw err }
        onProgress(totalSize, totalSize, "Uploaded \(filename)")
    }

    /// Download a remote directory with per-file progress tracking.
    ///
    /// Walks the remote directory tree, then downloads files one at a time
    /// so progress is tracked across the entire operation.
    func sftpDownloadDirectoryWithProgress(
        site: Site,
        remotePath: String,
        localPath: String,
        onProgress: TransferProgress
    ) throws {
        let dirName = (remotePath as NSString).lastPathComponent
        onProgress(0, 0, "Scanning remote directory: \(dirName)...")

        let remoteFiles = try sftpListFilesRecursive(site: site, remotePath: remotePath)
        let totalSize = remoteFiles.reduce(Int64(0)) { $0 + $1.size }
        let totalLabel = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)

        onProgress(0, totalSize, "Source size: \(totalLabel) (\(remoteFiles.count) files)")

        var transferred: Int64 = 0

        for entry in remoteFiles {
            // Build relative path under the destination.
            let relative = String(entry.path.dropFirst(remotePath.count))
            let localFile = (localPath as NSString).appendingPathComponent(
                (dirName as NSString).appendingPathComponent(relative)
            )

            // Ensure parent directories exist locally.
            let parentDir = (localFile as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir, withIntermediateDirectories: true
            )

            let filename = (entry.path as NSString).lastPathComponent
            onProgress(transferred, totalSize, "Downloading \(filename)...")

            // Transfer individual file.
            var args = buildSCPArgs(site: site, recursive: false)
            args.append(buildSCPRemote(site: site, remotePath: entry.path))
            args.append(localFile)
            try executeSCP(site: site, scpArgs: args)

            transferred += entry.size
            onProgress(transferred, totalSize, "Downloaded \(filename)")
        }

        onProgress(totalSize, totalSize, "Directory download complete")
    }

    /// Upload a local directory with per-file progress tracking.
    ///
    /// Walks the local directory tree, then uploads files one at a time
    /// so progress is tracked across the entire operation.
    func sftpUploadDirectoryWithProgress(
        site: Site,
        localPath: String,
        remotePath: String,
        onProgress: TransferProgress
    ) throws {
        let dirName = (localPath as NSString).lastPathComponent
        onProgress(0, 0, "Scanning local directory: \(dirName)...")

        // Walk local directory.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: localPath) else {
            throw ConnectorError.connectionFailed("Cannot read local directory")
        }

        var localFiles: [(path: String, relativePath: String, size: Int64)] = []
        while let relative = enumerator.nextObject() as? String {
            let full = (localPath as NSString).appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            let attrs = try fm.attributesOfItem(atPath: full)
            let size = (attrs[.size] as? Int64) ?? 0
            localFiles.append((path: full, relativePath: relative, size: size))
        }

        let totalSize = localFiles.reduce(Int64(0)) { $0 + $1.size }
        let totalLabel = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)

        onProgress(0, totalSize, "Source size: \(totalLabel) (\(localFiles.count) files)")

        // Ensure remote base directory exists.
        let mkdirResult = try executeSSHCommand(
            site: site,
            command: "mkdir -p \(remotePath.shellQuoted)"
        )
        if mkdirResult.exitCode != 0 {
            throw ConnectorError.connectionFailed("Failed to create remote directory")
        }

        var transferred: Int64 = 0

        for entry in localFiles {
            let filename = (entry.relativePath as NSString).lastPathComponent
            let remoteFile = "\(remotePath)/\(entry.relativePath)"

            // Ensure parent directory exists on remote.
            let remoteParent = (remoteFile as NSString).deletingLastPathComponent
            _ = try? executeSSHCommand(
                site: site,
                command: "mkdir -p \(remoteParent.shellQuoted)"
            )

            onProgress(transferred, totalSize, "Uploading \(filename)...")

            var args = buildSCPArgs(site: site, recursive: false)
            args.append(entry.path)
            args.append(buildSCPRemote(site: site, remotePath: remoteFile))
            try executeSCP(site: site, scpArgs: args)

            transferred += entry.size
            onProgress(transferred, totalSize, "Uploaded \(filename)")
        }

        onProgress(totalSize, totalSize, "Directory upload complete")
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
