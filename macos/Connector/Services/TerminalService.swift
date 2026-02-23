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

        return PlatformInfo(
            system: "Darwin",
            systemLabel: "macOS",
            terminal: terminal,
            hasSshpass: hasSshpass
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
        let cmd = buildSSHCommand(
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
            return buildSSHCommand(
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

    /// Build a shell-safe `ssh` command string.
    private func buildSSHCommand(
        hostname: String,
        port: Int,
        username: String,
        keyPath: String = "",
        password: String = "",
        sshVersion: Int = 2
    ) -> String {
        var parts = ["ssh"]
        if sshVersion == 1 {
            parts += ["-o", "Protocol=1"]
        }
        if !keyPath.isEmpty {
            let expanded = NSString(string: keyPath).expandingTildeInPath
            parts += ["-i", expanded]
        }
        if port != 22 {
            parts += ["-p", String(port)]
        }
        if !username.isEmpty {
            parts.append("\(username)@\(hostname)")
        } else {
            parts.append(hostname)
        }

        let sshCmd = parts.map(\.shellQuoted).joined(separator: " ")

        if !password.isEmpty && platformInfo.hasSshpass {
            let safePw = password.shellQuoted
            return "export SSHPASS=\(safePw); sshpass -e \(sshCmd); unset SSHPASS"
        }

        return sshCmd
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
        var args = ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10"]

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

        let remote: String
        if !site.username.isEmpty {
            remote = "\(site.username)@\(site.hostname):\(remotePath)"
        } else {
            remote = "\(site.hostname):\(remotePath)"
        }
        args.append(remote)
        args.append(localPath)

        let process = Process()
        var askpassURL: URL?

        if isPasswordAuth {
            if platformInfo.hasSshpass {
                // Use sshpass if available
                var env = ProcessInfo.processInfo.environment
                env["SSHPASS"] = site.password
                process.environment = env
                process.executableURL = URL(fileURLWithPath: Self.which("sshpass") ?? "/usr/local/bin/sshpass")
                process.arguments = ["-e", "scp"] + args
            } else {
                // Use SSH_ASKPASS (built into macOS OpenSSH)
                let scriptURL = try createAskpassScript(password: site.password)
                askpassURL = scriptURL
                configurePasswordEnvironment(process: process, password: site.password, askpassURL: scriptURL)
                process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
                process.arguments = args
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
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
            let errMsg = String(data: errData, encoding: .utf8) ?? "Download failed"
            throw ConnectorError.connectionFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Upload a local file using `scp`.
    func sftpUpload(site: Site, localPath: String, remotePath: String) throws {
        var args = ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10"]

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

        args.append(localPath)

        let remote: String
        if !site.username.isEmpty {
            remote = "\(site.username)@\(site.hostname):\(remotePath)"
        } else {
            remote = "\(site.hostname):\(remotePath)"
        }
        args.append(remote)

        let process = Process()
        var askpassURL: URL?

        if isPasswordAuth {
            if platformInfo.hasSshpass {
                var env = ProcessInfo.processInfo.environment
                env["SSHPASS"] = site.password
                process.environment = env
                process.executableURL = URL(fileURLWithPath: Self.which("sshpass") ?? "/usr/local/bin/sshpass")
                process.arguments = ["-e", "scp"] + args
            } else {
                let scriptURL = try createAskpassScript(password: site.password)
                askpassURL = scriptURL
                configurePasswordEnvironment(process: process, password: site.password, askpassURL: scriptURL)
                process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
                process.arguments = args
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
        }

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        defer { if let url = askpassURL { try? FileManager.default.removeItem(at: url) } }

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Upload failed"
            throw ConnectorError.connectionFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
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
