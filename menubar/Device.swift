import AppKit

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
