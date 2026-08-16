import AppKit

// MARK: - Shell helpers (run off the main thread; adb can block for seconds)

struct Shell {
    /// Environment for child processes.
    ///
    /// Critical: scrcpy invokes `adb` **by name**, and when this app is started by
    /// launchd it inherits a minimal PATH with no /opt/homebrew/bin — scrcpy then
    /// dies with "Command not found: [adb]". So set ADB explicitly (scrcpy honours
    /// it) and prepend Homebrew to PATH.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = Config.adb
        // Whichever directory adb was actually found in — not a fixed Homebrew
        // path — so scrcpy's own `adb` lookup lands on the same binary.
        let toolDir = (Config.adb as NSString).deletingLastPathComponent
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !existing.split(separator: ":").contains(Substring(toolDir)) {
            env["PATH"] = "\(toolDir):\(existing)"
        }
        return env
    }

    /// Runs a binary and returns (exitCode, stdout+stderr).
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.environment = childEnvironment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "failed to launch \(launchPath): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// A handle on the log, opened O_APPEND so every write lands at the end
    /// atomically. That matters because the file has three writers at once: this
    /// app, every detached scrcpy whose output is redirected here, and launchd,
    /// which points the agent's stdout and stderr at the same path. Seeking to
    /// the end first — as this used to — races all three and silently overwrites
    /// whatever another writer put there in between.
    private static func appendHandle() -> FileHandle? {
        let fd = open(Config.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Launches a detached process and returns immediately, appending output to the log.
    static func launchDetached(_ launchPath: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.environment = childEnvironment
        if let handle = appendHandle() {
            task.standardOutput = handle
            task.standardError = handle
        }
        try? task.run()   // deliberately not waited on
    }

    /// Blocking pause. Wrapped so it can be called from the detached tasks below
    /// without tripping Thread.sleep's async-context availability diagnostic.
    static func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    static func log(_ message: String) {
        let line = "=== \(Date()) \(message) ===\n"
        guard let data = line.data(using: .utf8), let handle = appendHandle() else { return }
        handle.write(data)
        try? handle.close()
    }
}
