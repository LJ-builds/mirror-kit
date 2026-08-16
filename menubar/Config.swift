// Tab Mirror — menu bar control for scrcpy mirroring of Gary's Android devices
// (Galaxy Tab S10 Ultra and Galaxy Z Fold 8) over Tailscale. Shows live
// connection state and starts/stops the mirror.
//
// Build: ./build.sh   (produces /Applications/Tab Mirror.app)

import AppKit

// MARK: - Configuration

enum Config {
    /// One place to change if the repository is ever renamed or moved. The
    /// issue tracker is the only support channel this app has, so a wrong URL
    /// here means bug reports quietly go nowhere.
    static let projectURL = "https://github.com/LJ-builds/mirror-kit"
    static let issuesURL = projectURL + "/issues"
    static let sponsorURL = "https://github.com/sponsors/LJ-builds"

    /// Look the tools up rather than hard-coding a Homebrew prefix: an Intel
    /// Mac uses /usr/local, an Android Studio install puts adb under
    /// ~/Library/Android, and MacPorts uses /opt/local. PATH is searched first,
    /// but launchd hands this app a minimal PATH, so in practice the fallback
    /// list is what usually answers.
    ///
    /// Deliberately does not shell out: Shell.run needs Config.adb, so anything
    /// spawning a process here would be circular.
    private static func locate(_ name: String) -> String {
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Android/sdk/platform-tools"),
            "/opt/local/bin",
        ]
        for dir in dirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        // Nothing found. Return a plausible path so the failure names something
        // real instead of an empty string.
        return "/opt/homebrew/bin/\(name)"
    }

    static let adb = locate("adb")
    static let scrcpy = locate("scrcpy")

    /// True when the tools could not actually be found, so the UI can say so
    /// instead of failing with a confusing "launch failed".
    static var toolsMissing: Bool {
        let fm = FileManager.default
        return !fm.isExecutableFile(atPath: adb) || !fm.isExecutableFile(atPath: scrcpy)
    }

    static var logPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/tab-mirror.log")
    }
}

/// One mirrorable Android device. Everything device-specific lives here so the
/// rest of the app never hard-codes a host again.
