import AppKit

// MARK: - Starting at login

/// Owned by the app rather than by the installer.
///
/// `install.sh` used to write this plist, which meant the only way to change
/// the setting was to re-run a shell script — and a Homebrew install has no
/// installer to write it from at all. The app knows where it lives and can turn
/// its own agent on and off, so it does.
enum LoginItem {
    static let label = "com.mirrorkit.menubar"

    static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Homebrew installs into a Cellar directory with the version in its path,
    /// and replaces that directory wholesale on upgrade — so an agent pointing
    /// into it starts failing the first time you `brew upgrade`. Alongside it
    /// Homebrew maintains an `opt` symlink whose path never changes, which is
    /// the one to point at.
    ///
    /// Anything not under a Cellar (a /Applications install, a build in a
    /// working copy) is already stable and is returned untouched.
    static func stablePath(for executable: String) -> String {
        guard let cellar = executable.range(of: "/Cellar/") else { return executable }
        let prefix = String(executable[..<cellar.lowerBound])
        let rest = String(executable[cellar.upperBound...])
        // "<formula>/<version>/<everything else>"
        let parts = rest.split(separator: "/", maxSplits: 2,
                               omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty else { return executable }
        return "\(prefix)/opt/\(parts[0])/\(parts[2])"
    }

    /// The path the agent should launch: this very binary, by its stable name.
    static var launchPath: String {
        stablePath(for: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    @discardableResult
    static func enable() -> Bool {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [launchPath],
            "RunAtLoad": true,
            // The same file everything else logs to, so a login-time failure
            // lands where the README already tells people to look.
            "StandardOutPath": Config.logPath,
            "StandardErrorPath": Config.logPath,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            let url = URL(fileURLWithPath: plistPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            Shell.log("could not write login item: \(error)")
            return false
        }
        // Boot it out first: bootstrap fails outright if the label is already
        // loaded, which it is on every run after the first.
        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let (status, out) = Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath])
        if status != 0 {
            Shell.log("launchctl bootstrap failed (\(status)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        Shell.log("login item enabled → \(launchPath)")
        return status == 0
    }

    static func disable() {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        Shell.log("login item disabled")
    }

    static func set(_ enabled: Bool) {
        enabled ? { _ = enable() }() : disable()
    }
}

// MARK: - The `mirror` command

/// Putting the CLI on the PATH from inside the app, the way an editor offers to
/// install its own shell command. A Homebrew install already has it; anyone who
/// built the app by hand may not, and the alternative is a README paragraph
/// about editing ~/.zshrc.
enum CommandLineTool {
    /// Where the CLI ships inside the app bundle. install.sh and the Homebrew
    /// formula both put a copy here so the app can hand it out.
    static var bundledScript: String? {
        Bundle.main.path(forResource: "mirror", ofType: nil)
    }

    /// Homebrew already links its own `bin`, so there is nothing to offer.
    static var isOnPath: Bool {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        // launchd hands this app a minimal PATH, so the usual bin directories
        // are checked too rather than trusted to be listed.
        let candidates = dirs + ["/opt/homebrew/bin", "/usr/local/bin",
                                 (NSHomeDirectory() as NSString).appendingPathComponent("bin")]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent("mirror")) }
    }

    /// `~/bin` rather than /usr/local/bin: no administrator password, and the
    /// README's PATH advice already names it.
    static var destination: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("bin/mirror")
    }

    static var destinationOnPath: Bool {
        let dir = (destination as NSString).deletingLastPathComponent
        return (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).contains(dir)
    }

    @discardableResult
    static func install() -> Bool {
        guard let source = bundledScript else { return false }
        let url = URL(fileURLWithPath: destination)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: destination)
        } catch {
            Shell.log("could not install the mirror command: \(error)")
            return false
        }
        Shell.log("installed the mirror command at \(destination)")
        return true
    }
}
