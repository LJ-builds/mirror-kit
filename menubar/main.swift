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
struct Device {
    let id: String                  // prefs namespace, stable across renames
    let menuName: String
    let host: String                // LAN or Tailscale address; "" = USB only
    let port: String                // pinned via `adb tcpip <port>`
    let windowTitle: String
    /// Model prefixes used to recognise this device when it shows up on USB as a
    /// bare serial. Several devices can be plugged in at once, so a bare serial
    /// alone is ambiguous — we ask the device what it is.
    let usbModelPrefixes: [String]
    let readySymbols: [String]      // tried in order; missing SF Symbols yield nil
    let mirroringSymbols: [String]
    /// Tablets only: their natural orientation is portrait, so mirroring one flat
    /// gives a tall strip unless the device itself is rotated. Phones don't want
    /// this, so it follows the configured `kind`.
    let supportsForceLandscape: Bool
    /// Some devices (the Galaxy Z Fold 8 on Android 17, verified 2026-08-15)
    /// stop their capture pipeline dead when scrcpy asks for --turn-screen-off:
    /// the encoder produces zero frames and the mirror is permanently black.
    let screenOffBreaksCapture: Bool
    /// Directory that files dropped on the mirror window are pushed into.
    let pushTarget: String

    var target: String { "\(host):\(port)" }

    /// Shown when nothing is configured yet, so every call site can keep
    /// assuming a device exists. It can never connect — the menu spots the
    /// empty list and offers `mirror add` instead of a Start item.
    static let placeholder = Device(
        id: "none",
        menuName: "No devices configured",
        host: "",
        port: "5555",
        windowTitle: "",
        usbModelPrefixes: [],
        readySymbols: ["questionmark.circle"],
        mirroringSymbols: ["questionmark.circle"],
        supportsForceLandscape: false,
        screenOffBreaksCapture: false,
        pushTarget: defaultPushTarget)

    // MARK: Loading

    /// The same file the `mirror` CLI reads, so adding a device in one place
    /// adds it in both.
    static var configPath: String {
        if let override = ProcessInfo.processInfo.environment["MIRROR_CONFIG"] {
            return (override as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/mirror/devices.json")
    }

    private static func parse(_ entry: [String: Any]) -> Device? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        let name = entry["name"] as? String ?? id
        // A tablet's natural orientation is portrait, so mirroring it flat gives
        // a tall strip unless the device itself is rotated. Phones never want
        // that, which is why the option follows `kind` rather than being asked.
        let isTablet = (entry["kind"] as? String)?.lowercased() == "tablet"
        let port: String
        if let number = entry["port"] as? Int { port = String(number) }
        else { port = entry["port"] as? String ?? "5555" }

        return Device(
            id: id,
            menuName: name,
            host: entry["host"] as? String ?? "",
            port: port,
            windowTitle: entry["title"] as? String ?? name,
            usbModelPrefixes: entry["usbModelPrefixes"] as? [String] ?? [],
            readySymbols: isTablet ? ["ipad.landscape"] : ["iphone"],
            mirroringSymbols: isTablet
                ? ["ipad.landscape.badge.play", "ipad.landscape"]
                : ["iphone.badge.play", "play.rectangle.fill", "iphone"],
            supportsForceLandscape: isTablet,
            screenOffBreaksCapture: entry["screenOffBreaksCapture"] as? Bool ?? false,
            pushTarget: entry["pushTarget"] as? String ?? defaultPushTarget)
    }

    /// Where files dropped onto the mirror window land. scrcpy's own default is
    /// the device's Downloads folder, which quickly becomes indistinguishable
    /// from everything the phone downloaded itself — so they get their own
    /// subfolder, overridable per device with "pushTarget" in devices.json.
    static let defaultPushTarget = "/sdcard/Download/FromMac/"

    static func load() -> [Device] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["devices"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap(parse)
    }

    /// Re-read on demand: the CLI's `mirror add` can write this file while the
    /// menu bar app is running, and the menu is rebuilt on every open anyway.
    private(set) static var all: [Device] = load()

    static func reload() { all = load() }
}

/// Which device the menu is currently driving. Persisted so the app comes back
/// pointing at whatever was last used.
enum Selection {
    private static let key = "selectedDevice"

    static var current: Device {
        get {
            let id = UserDefaults.standard.string(forKey: key)
            if let id, let match = Device.all.first(where: { $0.id == id }) {
                return match
            }
            // Either nothing has been chosen yet, or the chosen device was
            // removed from the config since. Fall back to the first one.
            return Device.all.first ?? .placeholder
        }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }
}

/// User-flippable options, persisted across launches and kept *per device* —
/// the tablet and the phone want genuinely different defaults.
enum Prefs {
    private static func key(_ name: String, _ device: Device) -> String {
        "\(device.id).\(name)"
    }

    private static func flag(_ name: String, _ device: Device) -> Bool {
        UserDefaults.standard.bool(forKey: key(name, device))
    }

    private static func setFlag(_ name: String, _ device: Device, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key(name, device))
    }

    /// UHID mouse: Android draws a real pointer on the device's own screen, but
    /// scrcpy must capture the Mac pointer to send relative motion. Press left
    /// Cmd or Option to release capture. Off by default — capture is intrusive.
    static func deviceCursor(_ d: Device) -> Bool { flag("deviceCursor", d) }
    static func setDeviceCursor(_ d: Device, _ v: Bool) { setFlag("deviceCursor", d, v) }

    /// UHID keyboard: keystrokes go through the device's own IME, so Chinese
    /// input works. Default mode drops non-ASCII characters entirely.
    static func uhidKeyboard(_ d: Device) -> Bool { flag("uhidKeyboard", d) }
    static func setUhidKeyboard(_ d: Device, _ v: Bool) { setFlag("uhidKeyboard", d, v) }

    /// Tab only. Its natural orientation is portrait (1848x2960), so lying flat
    /// with auto-rotate on it stays portrait and mirrors as a tall strip. No
    /// client-side flag fixes that — rotating the video would just turn the
    /// portrait UI sideways — so the device itself has to be rotated.
    static func forceLandscape(_ d: Device) -> Bool {
        d.supportsForceLandscape && flag("forceLandscape", d)
    }
    static func setForceLandscape(_ d: Device, _ v: Bool) { setFlag("forceLandscape", d, v) }

    /// Forward the device's audio to the Mac. Off by default: it adds latency to
    /// the stream and is usually not what you want for a screen you're driving.
    static func streamAudio(_ d: Device) -> Bool { flag("streamAudio", d) }
    static func setStreamAudio(_ d: Device, _ v: Bool) { setFlag("streamAudio", d, v) }

    // There was an option here to keep the device playing while forwarding
    // (--audio-source=playback --audio-dup). Removed: the two outputs run on
    // separate clocks with a network in between, so they drift audibly out of
    // step and the result is worse than either alone.

    /// Console-style streaming: buffer both streams generously so jitter is
    /// absorbed instead of showing up as stutter and crackle. Costs a quarter
    /// second of lag, which is nothing while watching and awful while pointing.
    static func watchMode(_ d: Device) -> Bool { flag("watchMode", d) }
    static func setWatchMode(_ d: Device, _ v: Bool) { setFlag("watchMode", d, v) }

    /// Full device resolution instead of the 1920px cap, plus a higher bitrate.
    /// The tablet panel is 1848x2960, so the cap was visibly softening it.
    static func sharpVideo(_ d: Device) -> Bool { flag("sharpVideo", d) }
    static func setSharpVideo(_ d: Device, _ v: Bool) { setFlag("sharpVideo", d, v) }

    /// One step below Smooth: fewer pixels and a lower bitrate again, for when
    /// the link is metered or weak and data matters more than detail. Only
    /// meaningful on Wi-Fi — USB always gets the full-quality profile.
    static func frugalVideo(_ d: Device) -> Bool { flag("frugalVideo", d) }
    static func setFrugalVideo(_ d: Device, _ v: Bool) { setFlag("frugalVideo", d, v) }

    static func registerDefaults() {
        migrateFromLegacyBundle()

        // Smooth by default on Wi-Fi: full resolution over the network costs more
        // frames than it gains detail. Defaults follow the device's kind, since
        // that is the thing that actually decides what it wants.
        var defaults: [String: Any] = [:]
        for device in Device.all {
            defaults[key("sharpVideo", device)] = false
            if device.supportsForceLandscape {
                defaults[key("forceLandscape", device)] = true
            } else {
                // A phone gets mirrored over Wi-Fi from wherever it happens to
                // be, so default it to the data-saving profile.
                defaults[key("frugalVideo", device)] = true
            }
        }
        UserDefaults.standard.register(defaults: defaults)
        migrateSingleDevicePrefs()
    }

    /// v3 and earlier shipped under the bundle id `com.gary.tab-mirror`, which
    /// put every setting in a different preferences domain. Copy them across
    /// once so renaming the app doesn't silently reset what the user picked.
    private static func migrateFromLegacyBundle() {
        let defaults = UserDefaults.standard
        let doneKey = "migratedFromLegacyBundle"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        guard let legacy = UserDefaults(suiteName: "com.gary.tab-mirror"),
              let values = legacy.persistentDomain(forName: "com.gary.tab-mirror")
        else { return }
        for (name, value) in values where defaults.object(forKey: name) == nil {
            defaults.set(value, forKey: name)
        }
    }

    /// v2 stored one global set of options back when there was only ever one
    /// device. Fold those into the first device's namespace so upgrading
    /// doesn't silently reset the settings already picked.
    private static func migrateSingleDevicePrefs() {
        let defaults = UserDefaults.standard
        let doneKey = "migratedToPerDevicePrefs"
        guard !defaults.bool(forKey: doneKey), let first = Device.all.first else { return }
        for name in ["deviceCursor", "uhidKeyboard", "forceLandscape", "streamAudio", "sharpVideo"] {
            if defaults.object(forKey: name) != nil {
                defaults.set(defaults.bool(forKey: name), forKey: key(name, first))
                defaults.removeObject(forKey: name)
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}

enum MirrorState {
    case mirroring       // scrcpy is up
    case ready           // device reachable over adb, not mirroring
    case unreachable     // can't see the device

    /// Candidates in preference order — SF Symbol availability varies by macOS
    /// version, and a nil image would leave the menu bar blank.
    func symbolNames(for device: Device) -> [String] {
        switch self {
        case .mirroring:   return device.mirroringSymbols
        case .ready:       return device.readySymbols
        case .unreachable: return ["display.trianglebadge.exclamationmark", "exclamationmark.triangle"]
        }
    }

    func label(for device: Device) -> String {
        let noun = device.supportsForceLandscape ? "Tablet" : "Phone"
        switch self {
        case .mirroring:   return "Mirroring"
        case .ready:       return "\(noun) ready"
        case .unreachable: return "\(noun) unreachable"
        }
    }
}

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

    /// Launches a detached process and returns immediately, appending output to the log.
    static func launchDetached(_ launchPath: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.environment = childEnvironment
        if !FileManager.default.fileExists(atPath: Config.logPath) {
            FileManager.default.createFile(atPath: Config.logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: Config.logPath) {
            handle.seekToEndOfFile()
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
        if !FileManager.default.fileExists(atPath: Config.logPath) {
            FileManager.default.createFile(atPath: Config.logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: Config.logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        }
    }
}

// MARK: - Mirror control

/// How we're talking to the tablet. USB has far more bandwidth than Wi-Fi, so it
/// gets the smooth profile without asking.
struct Link {
    let serial: String
    let isUSB: Bool
}

struct Mirror {
    /// Only this device's mirror. Both devices can be mirrored at once, so the
    /// match has to include the serial rather than any scrcpy at all.
    /// Every mirror session carries `--stay-awake`, and the keyboard-only session
    /// never does — that's what keeps the two from being mistaken for each other,
    /// since both are "scrcpy -s <serial>".
    static let mirrorMarker = "--stay-awake"

    /// Volume levels to hand back when the mirror stops, keyed by device id.
    nonisolated(unsafe) static var savedMediaVolume: [String: Int] = [:]

    static func isMirroring(_ device: Device) -> Bool {
        for serial in knownSerials(device) {
            let (status, _) = Shell.run("/usr/bin/pgrep",
                                        ["-f", "scrcpy -s \(serial) \(mirrorMarker)"])
            if status == 0 { return true }
        }
        return false
    }

    /// Serials this device could currently be attached under — the tailnet one
    /// plus a USB serial if it happens to be plugged in.
    static func knownSerials(_ device: Device) -> [String] {
        var serials = [device.target]
        if let usb = usbSerial(for: device) { serials.append(usb) }
        return serials
    }

    /// A bare serial (no host:port) is a USB attachment, but with two devices it
    /// no longer identifies *which*, so ask the device what model it is.
    private static func usbSerial(for device: Device) -> String? {
        // `adb devices -l`, not `adb devices`: a real USB attachment is the one
        // carrying a `usb:` field. Inferring it from "the serial has no colon"
        // is wrong, because wireless debugging advertises itself over mDNS as
        //   adb-XXXXXXXXXX-YYYYYY._adb-tls-connect._tcp
        // which has no colon either, and answers to the same model prefix — so
        // a phone on Wi-Fi got reported as USB and handed the USB bitrate.
        let (_, out) = Shell.run(Config.adb, ["devices", "-l"])
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                            .map(String.init).filter { !$0.isEmpty }
            guard parts.count >= 2, parts[1] == "device",
                  parts.contains(where: { $0.hasPrefix("usb:") }),
                  // Belt and braces: wireless debugging's mDNS name is not a cable
                  // whatever else the line says.
                  !parts[0].hasPrefix("adb-"),
                  !parts[0].contains("_adb-tls-connect") else { continue }
            let serial = parts[0]
            let (_, model) = Shell.run(Config.adb, ["-s", serial, "shell", "getprop ro.product.model"])
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if device.usbModelPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                return serial
            }
        }
        return nil
    }

    /// Prefers a USB attachment over the tailnet one — USB has far more bandwidth.
    static func currentLink(_ device: Device) -> Link? {
        if let usb = usbSerial(for: device) {
            return Link(serial: usb, isUSB: true)
        }
        let (_, out) = Shell.run(Config.adb, ["devices"])
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                            .map(String.init).filter { !$0.isEmpty }
            guard parts.count >= 2, parts[1] == "device" else { continue }
            if parts[0] == device.target { return Link(serial: parts[0], isUSB: false) }
        }
        return nil
    }

    static func isDeviceOnline(_ device: Device) -> Bool {
        currentLink(device) != nil
    }

    static func currentState(_ device: Device) -> MirrorState {
        if isMirroring(device) { return .mirroring }
        return isDeviceOnline(device) ? .ready : .unreachable
    }

    /// Tries to get adb into a connected state. Returns true on success.
    static func connect(_ device: Device) -> Bool {
        if isDeviceOnline(device) { return true }
        Shell.run(Config.adb, ["disconnect", device.target])
        Shell.run(Config.adb, ["connect", device.target])
        Thread.sleep(forTimeInterval: 1.0)
        return isDeviceOnline(device)
    }

    /// Re-pins adbd to the fixed port after a device reboot randomized it.
    static func repin(_ device: Device, from tempPort: String) -> Bool {
        let temp = "\(device.host):\(tempPort)"
        Shell.run(Config.adb, ["connect", temp])
        Thread.sleep(forTimeInterval: 1.0)

        let (_, out) = Shell.run(Config.adb, ["devices"])
        guard out.contains(temp) else { return false }

        Shell.log("re-pinning \(device.id) adbd from \(tempPort) to \(device.port)")
        Shell.run(Config.adb, ["-s", temp, "tcpip", device.port])
        Thread.sleep(forTimeInterval: 4.0)
        Shell.run(Config.adb, ["disconnect", temp])
        Shell.run(Config.adb, ["connect", device.target])
        Thread.sleep(forTimeInterval: 1.0)
        return isDeviceOnline(device)
    }

    /// USB always gets Smooth. On Wi-Fi it's the user's choice.
    static func useSmooth(for link: Link, _ device: Device) -> Bool {
        link.isUSB ? true : !Prefs.sharpVideo(device)
    }

    static func start(_ device: Device, screenOff: Bool) {
        guard let link = currentLink(device) else {
            Shell.log("start aborted: \(device.id) not connected")
            return
        }
        if Prefs.forceLandscape(device) { setLandscape(device, true) }

        let smooth = useSmooth(for: link, device)
        var args = [
            "-s", link.serial,
            "--stay-awake",
            // Reverse tunnelling fails intermittently over network adb
            // ("Server connection failed"); forward is reliable.
            "--force-adb-forward",
            // Always the physical screen: display 0 is the cover panel while the
            // phone is shut and the inner one once it's opened, and scrcpy follows
            // that switch, so there is nothing to choose between.
            "--display-id=0",
            // Where files dragged onto the window land.
            "--push-target=\(device.pushTarget)",
            "--window-title", device.windowTitle,
        ]

        if smooth && link.isUSB {
            // USB has bandwidth to spare, so spend it on pixels and quality.
            args.append(contentsOf: ["-m", "1920", "--video-codec=h265", "-b", "16M"])
        } else if smooth {
            // Over Wi-Fi the enemy is latency, not bandwidth: H.265 costs real
            // encode time on the phone, and every extra pixel is another frame's
            // worth of delay on a jittery link. H.264 at 1024/6M/60fps measurably
            // improved how the mirror felt on the fold (2026-08-15); 800/4M is
            // the frugal step down from that, chosen to save mobile data.
            args.append(contentsOf: [
                "-m", Prefs.frugalVideo(device) ? "800" : "1024",
                "--video-codec=h264",
                "-b", Prefs.frugalVideo(device) ? "4M" : "6M",
                "--max-fps=60"])
        } else {
            // Full panel, no downscaling. Sharper, fewer frames.
            args.append(contentsOf: ["-m", "0", "-b", "24M"])
        }

        // Jitter buffering, console-streaming style. scrcpy ships with none on
        // video and only 50ms on audio, so every jitter spike is a visible hitch
        // or an audible crackle. The two numbers must match: video buffering is
        // what keeps the picture level with the sound, and leaving video at 0
        // while audio waits 120ms is lip-sync error, not responsiveness.
        // Watch Mode buffers half a second. That is a lot by remote-control
        // standards and the whole point: when nobody is pointing at anything,
        // latency is free, and a deeper pool rides out the jitter spikes that a
        // shallow one only postpones.
        let bufferMs = Prefs.watchMode(device) ? 500 : (Prefs.streamAudio(device) ? 120 : 0)
        if bufferMs > 0 { args.append("--video-buffer=\(bufferMs)") }

        if !Prefs.streamAudio(device) {
            args.append("--no-audio")
        } else {
            args.append(contentsOf: ["--audio-bit-rate=192K",
                                     "--audio-buffer=\(bufferMs)"])
        }
        if screenOff && !device.screenOffBreaksCapture { args.append("--turn-screen-off") }
        if Prefs.deviceCursor(device) { args.append("--mouse=uhid") }
        if Prefs.uhidKeyboard(device) { args.append("--keyboard=uhid") }

        // adb push will not create a missing destination directory, so a drop
        // into a folder that doesn't exist yet fails with no visible error.
        Shell.run(Config.adb, ["-s", link.serial, "shell",
                               "mkdir -p '\(device.pushTarget)'"])

        Shell.log("starting \(device.id) mirror (link=\(link.isUSB ? "USB" : "wifi"), "
                  + "audio=\(Prefs.streamAudio(device)), "
                  + "profile=\(smooth ? "smooth" : "sharp"), "
                  + "screenOff=\(screenOff), "
                  + "cursor=\(Prefs.deviceCursor(device)), uhidKbd=\(Prefs.uhidKeyboard(device)))")
        Shell.launchDetached(Config.scrcpy, args)

        // Turn the capture gain up only *after* scrcpy has taken playback away
        // from the device. Doing it before launch — as this did at first — means
        // the phone spends the second or two of startup playing out of its own
        // speaker at maximum volume, which is a genuine jump scare.
        if Prefs.streamAudio(device) {
            Shell.pause(3.0)
            if let found = mediaVolume(link.serial), found < maxMediaVolume {
                // Never overwrite a level already put aside: across a restart the
                // volume we find is the zero this app just set, and saving that
                // would hand the device back permanently muted.
                if savedMediaVolume[device.id] == nil {
                    savedMediaVolume[device.id] = found
                }
                setMediaVolume(link.serial, maxMediaVolume)
                Shell.log("\(device.id) media volume \(found) → \(maxMediaVolume) for capture gain")
            }
        }
    }

    /// Silences the device across a restart. Changing quality means relaunching
    /// scrcpy, and the moment its audio process dies Android hands playback back
    /// to the phone's own speaker — so the two seconds between sessions come out
    /// loud, in whatever room the phone is in, at the volume this app raised for
    /// capture. Dropping it to zero for the gap makes the switch silent.
    static func silenceAcrossRestart(_ device: Device) {
        guard Prefs.streamAudio(device), let link = currentLink(device) else { return }
        if savedMediaVolume[device.id] == nil,
           let found = mediaVolume(link.serial), found < maxMediaVolume {
            savedMediaVolume[device.id] = found      // remember the human's level
        }
        setMediaVolume(link.serial, 0)
    }

    /// Stops only this device's mirror, leaving the other one running.
    static func stop(_ device: Device, restoreVolume: Bool = true) {
        for serial in knownSerials(device) {
            // Scoped to the mirror so a keyboard-only session survives. Plain
            // SIGTERM, never -9: a SIGKILLed scrcpy can leave a pointer stuck
            // down on the phone, which silently breaks all touch input.
            Shell.run("/usr/bin/pkill", ["-f", "scrcpy -s \(serial) \(mirrorMarker)"])
        }
        // Hand the device back in a normal state for hand-held use.
        if Prefs.forceLandscape(device) { setLandscape(device, false) }
        if restoreVolume, let level = savedMediaVolume.removeValue(forKey: device.id),
           let link = currentLink(device) {
            setMediaVolume(link.serial, level)
            Shell.log("\(device.id) media volume restored to \(level)")
        }
        Shell.log("\(device.id) mirror stopped")
    }

    /// The default audio source forwards the post-volume mix and silences the
    /// phone's own speaker, so the device's media volume is really the *gain* on
    /// what the Mac receives. Left at a normal listening level it hands the Mac
    /// a weak signal that then has to be amplified, hiss and all. Turned up it
    /// costs nothing, because the phone itself stays silent while forwarding.
    ///
    /// Returns the level it found, so it can be put back afterwards — otherwise
    /// the next notification after the mirror stops arrives at full blast.
    static let maxMediaVolume = 15

    static func mediaVolume(_ serial: String) -> Int? {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell",
                                              "cmd media_session volume --stream 3 --get"])
        // "[V] volume is 4 in range [0..15]"
        guard let line = out.split(separator: "\n").first(where: { $0.contains("volume is") }),
              let word = line.split(separator: " ").drop(while: { $0 != "is" }).dropFirst().first
        else { return nil }
        return Int(word)
    }

    static func setMediaVolume(_ serial: String, _ level: Int) {
        Shell.run(Config.adb, ["-s", serial, "shell",
                               "cmd media_session volume --stream 3 --set \(level)"])
    }

    /// Rotates the device itself. `user_rotation` 1 is 90° from the tablet's
    /// natural (portrait) orientation, i.e. landscape; auto-rotate has to be off
    /// for it to stick. The `-s` is not optional now that two devices can be
    /// attached at once — without it adb refuses with "more than one device".
    static func setLandscape(_ device: Device, _ on: Bool) {
        guard let link = currentLink(device) else { return }
        if on {
            Shell.run(Config.adb, ["-s", link.serial, "shell",
                                   "settings put system accelerometer_rotation 0; "
                                   + "settings put system user_rotation 1"])
        } else {
            Shell.run(Config.adb, ["-s", link.serial, "shell",
                                   "settings put system accelerometer_rotation 1"])
        }
        Shell.log("\(device.id) landscape lock = \(on)")
    }
}

// MARK: - Keyboard-only session

/// The Mac keyboard attached to the phone as a real USB keyboard, with no
/// mirroring at all: `--no-video` plus UHID, which works over TCP/IP. Android
/// sees a genuine `KEYBOARD | ALPHAKEY` device, so the phone's *own* IME handles
/// the keystrokes and Chinese input behaves exactly as with a Bluetooth keyboard.
///
/// scrcpy captures keystrokes through a window, so a small placeholder one opens
/// and has to be focused for anything to be forwarded — you watch the phone's own
/// screen while typing. (A truly windowless version is scrcpy's OTG mode, which
/// is USB-only.)
struct KeyboardOnly {
    /// Unique to this session type; the mirror never passes --no-video.
    static let marker = "--no-video"

    static func isRunning(_ device: Device) -> Bool {
        for serial in Mirror.knownSerials(device) {
            let (status, _) = Shell.run("/usr/bin/pgrep",
                                        ["-f", "scrcpy -s \(serial) \(marker)"])
            if status == 0 { return true }
        }
        return false
    }

    static func start(_ device: Device) {
        guard let link = Mirror.currentLink(device) else {
            Shell.log("keyboard-only aborted: \(device.id) not connected")
            return
        }
        Shell.log("starting \(device.id) keyboard-only session")
        Shell.launchDetached(Config.scrcpy, [
            "-s", link.serial,
            marker,
            "--no-audio",
            "--force-adb-forward",
            "--keyboard=uhid",
            // No pointer: capturing the Mac cursor into a placeholder window
            // would be baffling, and the ask was for the keyboard.
            "--mouse=disabled",
            "--window-title", "\(device.windowTitle) keyboard",
        ])
    }

    static func stop(_ device: Device) {
        for serial in Mirror.knownSerials(device) {
            Shell.run("/usr/bin/pkill", ["-f", "scrcpy -s \(serial) \(marker)"])
        }
        Shell.log("\(device.id) keyboard-only session stopped")
    }
}

// MARK: - Keyguard (auto-unlock)

/// Unlocks the device from the Mac so the *physical*-screen mirror stays usable
/// when the phone locks itself. (The virtual inner display never needs this —
/// it isn't behind the keyguard.) Sequence proven on the Fold 8: WAKEUP →
/// `wm dismiss-keyguard` (brings up the PIN bouncer) → `input text <PIN>` →
/// ENTER. A swipe-only keyguard falls away at the dismiss step, so the PIN is
/// only asked for when the device actually demands one.
struct Keyguard {
    /// Why an unlock attempt ended, so the UI can say something true instead of
    /// blaming the PIN for every failure.
    enum Result {
        case unlocked
        /// Samsung's "UnintentionalLcdOn" guard has the focus: the phone believes
        /// it was switched on by accident (folded shut in a bag, lying face down,
        /// proximity sensor covered) and swallows input, so the PIN prompt never
        /// even appears. No amount of retrying fixes it — the phone has to be
        /// uncovered or opened.
        case coveredByPocketGuard
        /// Woken and dismissed, but the PIN prompt never showed up in time.
        case promptNeverAppeared
        case pinRejected
    }

    static func isLocked(_ serial: String) -> Bool {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell",
                                              "dumpsys deviceidle | grep mScreenLocked"])
        return out.contains("mScreenLocked=true")
    }

    static func focusedWindow(_ serial: String) -> String {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell",
                                              "dumpsys window | grep mCurrentFocus"])
        return out
    }

    /// True while the phone thinks it's covered. Checked before and after the
    /// keyguard poke, since the guard can appear as a result of the wake.
    static func isPocketGuarded(_ serial: String) -> Bool {
        focusedWindow(serial).contains("UnintentionalLcdOn")
    }

    /// The device counts a wrong PIN; zero attempts means our keystrokes never
    /// reached the prompt, which is a different problem entirely.
    static func failedAttempts(_ serial: String) -> Int? {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell",
                                              "dumpsys lock_settings | grep 'failed attempt'"])
        guard let line = out.split(separator: "\n").first,
              let value = line.split(separator: "=").last else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    /// Wake and clear any non-secure keyguard. Returns true if still locked
    /// (i.e. a PIN is genuinely required).
    static func wakeAndDismiss(_ serial: String) -> Bool {
        Shell.run(Config.adb, ["-s", serial, "shell", "input keyevent KEYCODE_WAKEUP"])
        Shell.pause(1.0)
        Shell.run(Config.adb, ["-s", serial, "shell", "wm dismiss-keyguard"])
        Shell.pause(1.0)
        return isLocked(serial)
    }

    /// Waits for the PIN prompt to actually take focus. Typing before it does
    /// throws the digits into whatever window is up, which is how a perfectly
    /// good PIN ends up looking "wrong" while the device records zero attempts.
    static func waitForPrompt(_ serial: String, seconds: Double = 6.0) -> Bool {
        var waited = 0.0
        while waited < seconds {
            let focus = focusedWindow(serial)
            if focus.contains("Bouncer") { return true }
            if focus.contains("UnintentionalLcdOn") { return false }
            Shell.pause(0.5)
            waited += 0.5
        }
        return false
    }

    /// Types the PIN as individual key events rather than `input text` — the
    /// secure field takes those more reliably on One UI.
    static func enterPin(_ serial: String, _ pin: String) -> Bool {
        let codes = pin.compactMap { char -> String? in
            guard let digit = char.wholeNumberValue, (0...9).contains(digit) else { return nil }
            return "KEYCODE_\(digit)"          // KEYCODE_0 … KEYCODE_9
        }
        guard codes.count == pin.count, !codes.isEmpty else { return false }
        Shell.run(Config.adb, ["-s", serial, "shell",
                               "input keyevent \(codes.joined(separator: " "))"])
        Shell.run(Config.adb, ["-s", serial, "shell", "input keyevent KEYCODE_ENTER"])
        Shell.pause(1.5)
        return !isLocked(serial)
    }

    static func lock(_ serial: String) {
        Shell.run(Config.adb, ["-s", serial, "shell", "input keyevent KEYCODE_SLEEP"])
    }

    /// Runs the whole unlock with a PIN the user just typed. The PIN is never
    /// written anywhere — it lives only in this call.
    static func unlock(serial: String, pin: String) -> Result {
        if isPocketGuarded(serial) { return .coveredByPocketGuard }
        guard wakeAndDismiss(serial) else { return .unlocked }
        if isPocketGuarded(serial) { return .coveredByPocketGuard }
        guard waitForPrompt(serial) else {
            return isPocketGuarded(serial) ? .coveredByPocketGuard : .promptNeverAppeared
        }
        return enterPin(serial, pin) ? .unlocked : .pinRejected
    }

    /// Wake + dismiss only, for the case where no PIN is required at all.
    /// Returns true if that alone got the device unlocked.
    static func tryUnlockWithoutPin(_ serial: String) -> Bool {
        !wakeAndDismiss(serial)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    /// State of every device, so the menu can show at a glance which ones are up
    /// without blocking on adb while it's being drawn.
    private var states: [String: MirrorState] = [:]
    private var busy: Bool = false
    private var busyLabel: String = ""
    /// Remembered per device so a restart triggered by an option toggle preserves
    /// the mode the mirror was actually started in.
    private var lastScreenOff: [String: Bool] = [:]
    /// Devices whose mirror is up but blacked out behind a PIN prompt.
    private var lockedMidMirror: Set<String> = []
    /// Guards against the 6s poll stacking a new PIN dialog on every tick.
    private var promptingPin = false
    /// Devices whose PIN prompt the user dismissed. Cleared when the phone is
    /// seen unlocked again, so declining once doesn't mean never asking again —
    /// it means not asking again about *this* lock.
    private var pinDeclined: Set<String> = []
    /// Which devices currently have a keyboard-only session attached. Polled
    /// alongside mirror state so the menu's checkmark survives app restarts and
    /// notices a session closed from its own window.
    private var keyboardOnly: [String: Bool] = [:]
    /// True while a mirror session is running that *we* unlocked — those devices
    /// get locked back when their mirror stops, and left alone otherwise.
    private var autoUnlocked: [String: Bool] = [:]

    private var device: Device { Selection.current }
    private var state: MirrorState { states[device.id] ?? .unreachable }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Say what was loaded and from where. When someone's device does not
        // appear, this line is the difference between "the config is wrong" and
        // "the app is broken", and it is the first thing to ask them for.
        if Device.all.isEmpty {
            Shell.log("no devices in \(Device.configPath) — run `mirror add`")
        } else {
            let summary = Device.all
                .map { "\($0.id)=\($0.host.isEmpty ? "USB" : $0.target)" }
                .joined(separator: " ")
            Shell.log("loaded \(Device.all.count) device(s) from \(Device.configPath): \(summary)")
        }
        if Config.toolsMissing {
            Shell.log("scrcpy or adb missing (adb=\(Config.adb) scrcpy=\(Config.scrcpy))")
        }

        Prefs.registerDefaults()

        // The login agent and a manual launch can both fire; without this you get
        // two identical icons in the menu bar. Oldest instance wins.
        let mine = ProcessInfo.processInfo.processIdentifier
        // Read our own id rather than naming it: the bundle id changed when the
        // app was renamed, and a stale literal here would silently stop
        // deduplicating instead of failing visibly.
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.mirrorkit.menubar"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: myBundleID)
            .filter { $0.processIdentifier != mine }
        if others.contains(where: { $0.processIdentifier < mine }) {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateIcon()
        refreshState()

        // Poll so the icon reflects reality even when the menu is closed.
        timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: State

    private func refreshState() {
        guard !busy else { return }
        refreshStateForced()
    }

    /// Not every SF Symbol exists on every macOS version, and a nil image leaves
    /// the menu bar item invisible — so fall back down a list.
    private func symbol(_ names: [String], _ description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image
            }
        }
        return nil
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let label = state.label(for: device)
        let names = busy ? ["circle.dotted", "circle"] : state.symbolNames(for: device)
        let image = symbol(names, label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = busy ? busyLabel : "\(device.menuName) — \(label)"
    }

    private func setBusy(_ label: String) {
        busy = true
        busyLabel = label
        updateIcon()
    }

    private func clearBusy() {
        busy = false
        busyLabel = ""
        refreshStateForced()
    }

    private func refreshStateForced() {
        Task.detached {
            var polled: [String: MirrorState] = [:]
            var keys: [String: Bool] = [:]
            for device in Device.all {
                polled[device.id] = Mirror.currentState(device)
                keys[device.id] = KeyboardOnly.isRunning(device)
            }

            // A mirror that locks itself mid-session goes *black*, not to a
            // lockscreen: the PIN prompt is a secure window, and secure content
            // is blanked on the virtual display scrcpy captures through, so the
            // user cannot see what to type.
            //
            // Detection here must stay READ-ONLY. Poking the phone awake to find
            // out costs nothing the first time and is a disaster on a timer: the
            // wake raises the PIN prompt, the prompt blacks the mirror, and six
            // seconds later it happens again. `mScreenLocked` answers the
            // question without touching the device; waking is left to the moment
            // the user actually submits a PIN.
            var lockedNow: [String] = []
            for device in Device.all where polled[device.id] == .mirroring {
                if let link = Mirror.currentLink(device), Keyguard.isLocked(link.serial) {
                    lockedNow.append(device.id)
                }
            }

            let fresh = polled   // immutable copies: the closure below crosses actors
            let freshKeys = keys
            let locked = Set(lockedNow)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.states = fresh
                self.keyboardOnly = freshKeys
                self.lockedMidMirror = locked
                // Once a phone is unlocked again, forget that its prompt was
                // dismissed, so the next genuine lock asks afresh.
                self.pinDeclined.formIntersection(locked)
                self.updateIcon()
                // Ask once per lock episode. Re-asking every tick would be the
                // same nagging loop as re-waking every tick.
                if let id = locked.first, !self.pinDeclined.contains(id),
                   let device = Device.all.first(where: { $0.id == id }) {
                    self.promptForPinIfIdle(device)
                }
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Pick up devices added by `mirror add` while this app was running.
        Device.reload()

        // Nothing configured yet — a fresh install. Offer the one thing that
        // helps instead of an empty menu with dead controls.
        if Device.all.isEmpty {
            let title = NSMenuItem(title: "No devices configured",
                                   action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for line in ["    1. Plug the device in over USB",
                         "    2. Enable USB debugging on it",
                         "    3. Run  mirror add  in Terminal"] {
                let hint = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
            menu.addItem(.separator())
            menu.addItem(item("Open Log", #selector(openLog), ""))
            menu.addItem(item("Quit", #selector(quit), "q"))
            return
        }

        if Config.toolsMissing {
            let warn = NSMenuItem(title: "scrcpy or adb not found — brew install scrcpy android-platform-tools",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let device = self.device
        let link = Mirror.currentLink(device)

        // Device picker. Each row carries its own state, so one device's status
        // is visible while another is selected.
        for candidate in Device.all {
            let candidateState = states[candidate.id] ?? .unreachable
            let mark = candidateState == .mirroring ? "  ● mirroring"
                     : candidateState == .unreachable ? "  — offline" : ""
            let row = item(candidate.menuName + mark, #selector(selectDevice(_:)), "")
            row.representedObject = candidate.id
            row.state = candidate.id == device.id ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())

        var headerText = busy ? busyLabel : state.label(for: device)
        if !busy, state != .unreachable, let link {
            headerText += link.isUSB ? " (USB)" : " (Wi-Fi)"
        }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if busy {
            let wait = NSMenuItem(title: "Working…", action: nil, keyEquivalent: "")
            wait.isEnabled = false
            menu.addItem(wait)
        } else {
            switch state {
            case .mirroring:
                if lockedMidMirror.contains(device.id) {
                    // The mirror is up but showing a black rectangle, so this is
                    // the only useful thing to offer.
                    menu.addItem(item("Enter PIN to Unlock (mirror is blacked out)…",
                                      #selector(unlockNow), "u"))
                }
                menu.addItem(item("Stop Mirror", #selector(stopMirror), "s"))
            case .ready, .unreachable:
                menu.addItem(item("Start Mirror", #selector(startMirror), "m"))
                // Offered only where it works. On a phone whose capture dies with
                // the panel it is not a choice, and saying so in a dead menu row
                // spends a line telling the user what they cannot have.
                if !device.screenOffBreaksCapture && !Prefs.deviceCursor(device) {
                    menu.addItem(item("Start with Device Screen Off",
                                      #selector(startMirrorScreenOff), ""))
                }
            }

            // A separate session, not a mirror setting: useful precisely when you
            // are looking at the phone itself. Named so it cannot be confused
            // with the mirror's own keyboard option, which lives under Typing.
            let keysOn = keyboardOnly[device.id] ?? false
            let keys = item(keysOn ? "Stop Keyboard-Only Session"
                                   : "Keyboard Only — type with no mirror",
                            #selector(toggleKeyboardOnly), "k")
            keys.keyEquivalentModifierMask = [.command, .shift]
            keys.state = keysOn ? .on : .off
            menu.addItem(keys)

            menu.addItem(.separator())
            menu.addItem(item("Reconnect \(device.menuName)…", #selector(reconnectTablet), "r"))
        }

        menu.addItem(.separator())

        // Everything below is "how the mirror behaves" rather than "what to do
        // now", so it lives one level down. Two groups: what the picture costs,
        // and how input reaches the phone.
        menu.addItem(qualityMenuItem(device, link: link))
        menu.addItem(inputMenuItem(device))

        menu.addItem(.separator())
        menu.addItem(aboutMenuItem())
        menu.addItem(item("Open Log", #selector(openLog), ""))
        menu.addItem(item("Quit", #selector(quit), "q"))
    }

    /// "Picture & Sound": one axis of quality, plus the two things that change
    /// what the stream costs. The current pick is echoed in the parent title so
    /// the setting is readable without opening the submenu.
    private func qualityMenuItem(_ device: Device, link: Link?) -> NSMenuItem {
        let sub = NSMenu()
        let usb = link?.isUSB ?? false

        let levelName: String
        if usb {
            levelName = "full quality (USB)"
            let note = NSMenuItem(title: "USB connected — 1920, H.265",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
            let why = NSMenuItem(title: "Bandwidth to spare, so nothing to trade off.",
                                 action: nil, keyEquivalent: "")
            why.isEnabled = false
            sub.addItem(why)
        } else {
            let frugal = Prefs.frugalVideo(device), sharp = Prefs.sharpVideo(device)
            levelName = sharp ? "Sharpest" : (frugal ? "Smoothest" : "Medium")

            let smoothest = item("Smoothest — 800, least data", #selector(selectFrugal), "")
            smoothest.state = (!sharp && frugal) ? .on : .off
            sub.addItem(smoothest)

            let medium = item("Medium — 1024", #selector(selectSmooth), "")
            medium.state = (!sharp && !frugal) ? .on : .off
            sub.addItem(medium)

            let sharpest = item("Sharpest — full resolution", #selector(selectSharp), "")
            sharpest.state = sharp ? .on : .off
            sub.addItem(sharpest)
        }

        sub.addItem(.separator())

        // Say what turning this on costs. Sound cannot be buffered without the
        // picture being buffered by the same amount — otherwise it simply plays
        // late — so enabling audio slows the video down to meet it. That is a
        // real change in how the mirror feels, and it should not be a surprise.
        let audio = item("Stream Device Audio  (adds ~0.12s, keeps it in sync)",
                         #selector(toggleAudio), "")
        audio.state = Prefs.streamAudio(device) ? .on : .off
        sub.addItem(audio)
        if Prefs.streamAudio(device) && !Prefs.watchMode(device) {
            let hint = NSMenuItem(
                title: "    picture is held back to match the sound",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
        }

        let watch = item("Watch Mode — buffered, adds ~0.5s lag",
                         #selector(toggleWatchMode), "")
        watch.state = Prefs.watchMode(device) ? .on : .off
        sub.addItem(watch)
        let watchHint = NSMenuItem(
            title: "    steadier video; leave off while clicking around",
            action: nil, keyEquivalent: "")
        watchHint.isEnabled = false
        sub.addItem(watchHint)

        let parent = NSMenuItem(title: "Picture & Sound  (\(levelName))",
                                action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// "Input": everything about how the Mac's keyboard and pointer reach the
    /// device while mirroring. The keyboard-only session is deliberately *not*
    /// here — it is an action, not a property of the mirror.
    private func inputMenuItem(_ device: Device) -> NSMenuItem {
        let sub = NSMenu()

        // scrcpy fixes input modes at launch, so both of these relaunch the
        // mirror rather than switching it live.
        let kbd = item("Use Phone's Own Keyboard (IME)", #selector(toggleKeyboard), "k")
        kbd.state = Prefs.uhidKeyboard(device) ? .on : .off
        sub.addItem(kbd)
        let kbdHint = NSMenuItem(
            title: "    needed for Chinese; plain mode drops non-ASCII",
            action: nil, keyEquivalent: "")
        kbdHint.isEnabled = false
        sub.addItem(kbdHint)

        sub.addItem(.separator())

        let cursor = item("Show Cursor on Device", #selector(toggleCursor), "")
        cursor.state = Prefs.deviceCursor(device) ? .on : .off
        sub.addItem(cursor)
        let cursorHint = NSMenuItem(
            title: Prefs.deviceCursor(device)
                 ? "    press ⌘ or ⌥ to give the pointer back to the Mac"
                 : "    draws a pointer on the phone; adds a round trip of lag",
            action: nil, keyEquivalent: "")
        cursorHint.isEnabled = false
        sub.addItem(cursorHint)

        if device.supportsForceLandscape {
            sub.addItem(.separator())
            let land = item("Force Landscape on Tablet", #selector(toggleLandscape), "")
            land.state = Prefs.forceLandscape(device) ? .on : .off
            sub.addItem(land)
        }

        let parent = NSMenuItem(title: "Input & Typing", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// Kept behind one row on purpose. Reporting a bug is genuinely useful to
    /// someone mid-problem — this app is only tested on three Samsung devices,
    /// so other people's reports are the only way anything else gets fixed. But
    /// a menu is opened to get something done, and putting a donation link in
    /// the middle of that taxes every visit. One "About" holds both without
    /// either one standing in the way.
    private func aboutMenuItem() -> NSMenuItem {
        let sub = NSMenu()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "?"
        let stamp = NSMenuItem(title: "Mirror kit \(version)", action: nil, keyEquivalent: "")
        stamp.isEnabled = false
        sub.addItem(stamp)

        let scrcpyNote = NSMenuItem(title: "Mirroring by scrcpy", action: nil, keyEquivalent: "")
        scrcpyNote.isEnabled = false
        sub.addItem(scrcpyNote)

        sub.addItem(.separator())

        let report = item("Report an Issue…", #selector(openIssues), "")
        sub.addItem(report)
        let project = item("Project Page", #selector(openProject), "")
        sub.addItem(project)

        sub.addItem(.separator())

        let sponsor = item("Buy Me a Coffee", #selector(openSponsor), "")
        sub.addItem(sponsor)

        let parent = NSMenuItem(title: "About Mirror kit", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openIssues()  { open(Config.issuesURL) }
    @objc private func openProject() { open(Config.projectURL) }
    @objc private func openSponsor() { open(Config.sponsorURL) }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: Actions

    /// Switching device is just a preference flip; nothing is started or stopped,
    /// so a mirror already running on the other device keeps running.
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let picked = Device.all.first(where: { $0.id == id }),
              picked.id != device.id else { return }
        Selection.current = picked
        updateIcon()
        refreshStateForced()
    }

    @objc private func startMirror() { beginStart(screenOff: false) }
    @objc private func startMirrorScreenOff() { beginStart(screenOff: true) }

    private func beginStart(screenOff: Bool) {
        let device = self.device
        lastScreenOff[device.id] = screenOff
        setBusy("Connecting…")
        Task.detached {
            let connected = Mirror.connect(device)
            if !connected {
                await MainActor.run { [weak self] in
                    self?.clearBusy()
                    self?.promptForPort(device, thenStartScreenOff: screenOff)
                }
                return
            }

            // Capture sits behind the keyguard, so clear it before opening a
            // window onto a lockscreen that would just render black. Waking the
            // phone is fine *here* — the user asked for a mirror a moment ago.
            // It is only the background poll that must never do this, because
            // there the same wake repeats forever on a timer.
            if let link = Mirror.currentLink(device),
               Keyguard.isLocked(link.serial) {
                if Keyguard.isPocketGuarded(link.serial) {
                    await MainActor.run { [weak self] in
                        self?.clearBusy()
                        self?.alert(Self.pocketGuardMessage(device),
                                    Self.pocketGuardDetail)
                    }
                    return
                }
                // A swipe-only keyguard falls away here and never needs a PIN.
                if !Keyguard.tryUnlockWithoutPin(link.serial) {
                    // Needs the PIN. It is asked for every time and never stored,
                    // so hand back to the main actor to prompt.
                    await MainActor.run { [weak self] in
                        self?.clearBusy()
                        self?.promptForPin(device, thenStartScreenOff: screenOff)
                    }
                    return
                }
                Shell.log("\(device.id) unlocked (no PIN needed) for physical mirror")
                await MainActor.run { [weak self] in self?.autoUnlocked[device.id] = true }
            }

            Mirror.start(device, screenOff: screenOff)
            Shell.pause(4.0)

            // A stale device-side server can eat the first attach; retry once.
            if !Mirror.isMirroring(device) {
                Shell.log("first attach failed for \(device.id), retrying")
                Shell.run(Config.adb, ["disconnect", device.target])
                Shell.run(Config.adb, ["connect", device.target])
                Shell.pause(2.0)
                Mirror.start(device, screenOff: screenOff)
                Shell.pause(4.0)
            }

            let ok = Mirror.isMirroring(device)
            await MainActor.run { [weak self] in
                self?.clearBusy()
                if !ok { self?.alert("The mirror wouldn't start.",
                                     "Check the log for details: \(Config.logPath)") }
            }
        }
    }

    @objc private func stopMirror() {
        let device = self.device
        let relock = autoUnlocked[device.id] ?? false
        autoUnlocked[device.id] = false
        setBusy("Stopping…")
        Task.detached {
            Mirror.stop(device)
            // Leave the phone as we found it: if we unlocked it, lock it back.
            if relock, let link = Mirror.currentLink(device) {
                Keyguard.lock(link.serial)
                Shell.log("\(device.id) re-locked after mirror stop")
            }
            // Let the device-side server tear down so a quick restart works.
            Shell.pause(2.0)
            await MainActor.run { [weak self] in self?.clearBusy() }
        }
    }

    @objc private func reconnectTablet() {
        let device = self.device
        setBusy("Reconnecting…")
        Task.detached {
            let ok = Mirror.connect(device)
            await MainActor.run { [weak self] in
                self?.clearBusy()
                if !ok { self?.promptForPort(device, thenStartScreenOff: nil) }
            }
        }
    }

    /// After a device reboot the port is randomized. Ask for the new one, re-pin 5555,
    /// and optionally continue into starting the mirror.
    private func promptForPort(_ device: Device, thenStartScreenOff screenOff: Bool?) {
        let alert = NSAlert()
        alert.messageText = "Can't reach the \(device.menuName) on port \(device.port)"
        alert.informativeText = """
        It probably rebooted, which turns Wireless debugging off.

        On the device:
        Settings › Developer options › Wireless debugging › ON

        Then enter the port shown under "IP address & Port" \
        (the number after the colon):
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 33127"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let digits = field.stringValue.filter { $0.isNumber }
        guard !digits.isEmpty else {
            self.alert("That wasn't a port number.", "Try again from Reconnect.")
            return
        }

        setBusy("Re-pinning port…")
        Task.detached {
            let ok = Mirror.repin(device, from: digits)
            await MainActor.run { [weak self] in
                self?.clearBusy()
                guard let self else { return }
                if !ok {
                    self.alert("Still can't connect on port \(digits).",
                               "Check that the device is on the same network as this Mac "
                               + "— or, if you reach it over Tailscale, that Tailscale is "
                               + "up on both ends.\n\nIf it wants to pair again, run this "
                               + "in Terminal with the pairing code the device shows:\n"
                               + "    adb pair \(device.host):<pairing-port> <6-digit-code>")
                } else if let screenOff {
                    self.beginStart(screenOff: screenOff)
                }
            }
        }
    }

    static func pocketGuardMessage(_ device: Device) -> String {
        "The \(device.menuName) thinks it was switched on by accident"
    }

    static let pocketGuardDetail = """
    Its proximity sensor is covered — folded shut in a bag, lying face down, \
    or under something. While that guard is up the phone ignores everything \
    sent to it and the PIN prompt never appears.

    Pick the phone up (or open it), then try again.
    """

    /// Asks only if no PIN dialog is already up. The poll fires every 6s, and a
    /// phone that stays locked would otherwise stack dialogs on every tick.
    private func promptForPinIfIdle(_ device: Device) {
        guard !promptingPin else { return }
        promptForPin(device, thenStartScreenOff: nil)
    }

    /// The device demanded a PIN. It is asked for on every unlock and never
    /// written to disk, so this runs each time rather than once.
    ///
    /// `screenOff` nil means the mirror is already running and only the keyguard
    /// is in the way — typing the PIN here is the whole point, since the bouncer
    /// is a secure window and shows up in the mirror as an unreadable black
    /// rectangle. Nothing is restarted in that case; the picture comes back by
    /// itself the moment the phone unlocks.
    private func promptForPin(_ device: Device, thenStartScreenOff screenOff: Bool?) {
        promptingPin = true
        defer { promptingPin = false }

        let alert = NSAlert()
        alert.messageText = "Unlock the \(device.menuName)"
        alert.informativeText = screenOff == nil
            ? """
              It locked itself, so the mirror has gone black — the PIN screen is \
              a secure window and can't be shown or typed into remotely.

              Enter the PIN here instead and it will be typed on the phone for \
              you. It is used once and never saved.
              """
            : """
              Enter its screen-lock PIN so the mirror can get past the lockscreen.
              It is used for this unlock only and is never saved.
              """
        alert.addButton(withTitle: screenOff == nil ? "Unlock" : "Unlock & Mirror")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            pinDeclined.insert(device.id)      // don't nag again until it unlocks
            return
        }
        let pin = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else {
            pinDeclined.insert(device.id)
            return
        }

        setBusy("Unlocking…")
        Task.detached {
            guard let link = Mirror.currentLink(device) else {
                await MainActor.run { [weak self] in self?.clearBusy() }
                return
            }
            let result = Keyguard.unlock(serial: link.serial, pin: pin)
            Shell.log("\(device.id) unlock result: \(result)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.clearBusy()
                switch result {
                case .unlocked:
                    self.autoUnlocked[device.id] = true
                    self.lockedMidMirror.remove(device.id)
                    // Only start a mirror if this prompt was on the way to one;
                    // a mid-session unlock just un-blacks the picture already up.
                    if let screenOff { self.beginStart(screenOff: screenOff) }
                case .coveredByPocketGuard:
                    self.alert(Self.pocketGuardMessage(device), Self.pocketGuardDetail)
                case .promptNeverAppeared:
                    self.alert("The \(device.menuName) never showed its PIN prompt.",
                               "Nothing was typed, so no failed attempt was recorded. "
                               + "Wake the phone by hand once, then try again.")
                case .pinRejected:
                    self.alert("That PIN didn't unlock the \(device.menuName).",
                               "The phone rejected it — check the digits and try again. "
                               + "Nothing is stored, so the next attempt starts fresh.")
                }
            }
        }
    }

    @objc private func unlockNow() {
        promptForPin(device, thenStartScreenOff: nil)
    }

    @objc private func toggleCursor() {
        let device = self.device
        Prefs.setDeviceCursor(device, !Prefs.deviceCursor(device))
        // A pointer drawn on a dark screen is useless, so the two modes are
        // mutually exclusive: enabling the cursor drops screen-off.
        if Prefs.deviceCursor(device) { lastScreenOff[device.id] = false }
        restartIfMirroring()
    }

    @objc private func toggleKeyboard() {
        let device = self.device
        Prefs.setUhidKeyboard(device, !Prefs.uhidKeyboard(device))
        restartIfMirroring()
    }

    /// Starts or stops the keyboard-only session. It is deliberately independent
    /// of the mirror: both can run at once, and stopping one leaves the other.
    @objc private func toggleKeyboardOnly() {
        let device = self.device
        let running = keyboardOnly[device.id] ?? false
        keyboardOnly[device.id] = !running          // optimistic; the poll confirms
        setBusy(running ? "Detaching keyboard…" : "Attaching keyboard…")
        Task.detached {
            if running {
                KeyboardOnly.stop(device)
                Shell.pause(1.0)
            } else {
                if !Mirror.connect(device) {
                    await MainActor.run { [weak self] in
                        self?.keyboardOnly[device.id] = false
                        self?.clearBusy()
                        self?.promptForPort(device, thenStartScreenOff: nil)
                    }
                    return
                }
                KeyboardOnly.start(device)
                Shell.pause(3.0)
            }
            let ok = KeyboardOnly.isRunning(device)
            await MainActor.run { [weak self] in
                self?.keyboardOnly[device.id] = ok
                self?.clearBusy()
                if !running && !ok {
                    self?.alert("The keyboard wouldn't attach.",
                                "Check the log for details: \(Config.logPath)")
                }
            }
        }
    }

    @objc private func toggleAudio() {
        let device = self.device
        Prefs.setStreamAudio(device, !Prefs.streamAudio(device))
        restartIfMirroring()
    }

    @objc private func toggleWatchMode() {
        let device = self.device
        Prefs.setWatchMode(device, !Prefs.watchMode(device))
        restartIfMirroring()
    }

    @objc private func selectFrugal() {
        let device = self.device
        guard Prefs.sharpVideo(device) || !Prefs.frugalVideo(device) else { return }
        Prefs.setSharpVideo(device, false)
        Prefs.setFrugalVideo(device, true)
        restartIfMirroring()
    }

    @objc private func selectSmooth() {
        let device = self.device
        guard Prefs.sharpVideo(device) || Prefs.frugalVideo(device) else { return }
        Prefs.setSharpVideo(device, false)
        Prefs.setFrugalVideo(device, false)
        restartIfMirroring()
    }

    @objc private func selectSharp() {
        let device = self.device
        guard !Prefs.sharpVideo(device) else { return }
        Prefs.setSharpVideo(device, true)
        restartIfMirroring()
    }

    /// Rotation is a device setting, so it applies live — no restart needed.
    @objc private func toggleLandscape() {
        let device = self.device
        let on = !Prefs.forceLandscape(device)
        Prefs.setForceLandscape(device, on)
        Task.detached { Mirror.setLandscape(device, on) }
    }

    /// Input mode is fixed at scrcpy launch, so a live mirror has to be relaunched
    /// for a toggle to take effect.
    private func restartIfMirroring() {
        guard state == .mirroring else { return }
        let device = self.device
        setBusy("Restarting…")
        let keepScreenOff = lastScreenOff[device.id] ?? false
        Task.detached {
            Mirror.silenceAcrossRestart(device)
            Mirror.stop(device, restoreVolume: false)
            Shell.pause(2.0)
            Mirror.start(device, screenOff: keepScreenOff)
            Shell.pause(4.0)
            await MainActor.run { [weak self] in self?.clearBusy() }
        }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Config.logPath) {
            FileManager.default.createFile(atPath: Config.logPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.logPath))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
