import AppKit

// MARK: - What setup needs to learn from a cable, and the one thing it writes

/// The non-visual half of the welcome window: reading the device's own answers
/// off a USB cable, and writing the result into devices.json.
///
/// Deliberately split from the window, and split again into `parse` functions
/// that take a string and return a state. Everything here is decided by parsing
/// adb output, which is the part most likely to be wrong on a device nobody
/// here owns — so it is the part that has to be testable without a screen.
enum DeviceSetup {

    /// What the cable is currently offering.
    ///
    /// These are the states `adb devices` actually reports, kept apart because
    /// the difference between two of them is the difference between "plug it in"
    /// and "look at your phone, right now". Collapsing them is exactly why the
    /// old setup script answered a device waiting to be authorised with "No USB
    /// device found — enable USB debugging", telling people to redo the step
    /// they had just done while the real prompt sat unanswered on the screen.
    enum CableState: Equatable {
        case adbMissing
        case nothingPlugged
        /// Plugged in and talking, but waiting for "Allow USB debugging?" to be
        /// tapped on the device itself. Nothing on the Mac can clear this.
        case waitingForAuthorization
        /// Seen but not usable yet — the second or two after plugging in, a
        /// cable that only carries power, or a device still booting.
        case connecting
        case ready(Found)
    }

    struct Found: Equatable {
        let serial: String
        var manufacturer: String = ""
        var model: String = ""

        var label: String {
            let joined = "\(manufacturer) \(model)".trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? serial : joined
        }
        var isSamsung: Bool { manufacturer.lowercased().contains("samsung") }
    }

    // MARK: Reading the cable

    /// True when a serial names something plugged in rather than something on
    /// the network. A USB serial never contains a colon; wireless debugging is
    /// either `host:port` or the mDNS name `adb-XXXX._adb-tls-connect._tcp`,
    /// which has no colon either and is emphatically not a cable.
    ///
    /// The `usb:` field in `adb devices -l` is the other way to tell, and is
    /// what the mirroring code uses — but it is absent for a device that has not
    /// been authorised yet, which is precisely the case this has to get right.
    static func isCableSerial(_ serial: String) -> Bool {
        !serial.contains(":")
            && !serial.hasPrefix("adb-")
            && !serial.contains("_adb-tls-connect")
    }

    /// The states adb prints in the second column. A line is only a device line
    /// if its second word is one of these.
    ///
    /// Matching on the state rather than skipping known headers matters because
    /// `Shell.run` merges stderr into stdout, and adb greets a cold start with
    /// "* daemon not running; starting now at tcp:5037". That line's first word
    /// looks like a serial and its second like a state, so a parser that only
    /// skipped "List of devices attached" would read the daemon starting up as
    /// a device in an unknown state — and the window would say "Connecting…"
    /// at somebody who has not plugged anything in.
    private static let deviceStates: Set<String> = [
        "device", "unauthorized", "authorizing", "offline",
        "bootloader", "recovery", "sideload", "rescue", "host", "no",
    ]

    /// Turns `adb devices -l` output into a state. Pure, so it can be checked
    /// against real output from real devices without one being present.
    static func parse(devicesOutput out: String) -> CableState {
        var sawUnauthorized = false
        var sawOther = false
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .map(String.init).filter { !$0.isEmpty }
            guard parts.count >= 2,
                  deviceStates.contains(parts[1]),
                  isCableSerial(parts[0]) else { continue }
            switch parts[1] {
            case "device":       return .ready(Found(serial: parts[0]))
            case "unauthorized": sawUnauthorized = true
            // "authorizing" is the moment just after Allow is tapped, and
            // "offline"/"no permissions"/"recovery" are all seen-but-not-usable.
            // None of them is answered by telling somebody to tap anything.
            default:             sawOther = true
            }
        }
        if sawUnauthorized { return .waitingForAuthorization }
        return sawOther ? .connecting : .nothingPlugged
    }

    /// Asks the cable what it has, and — only once a device is authorised, since
    /// these properties are not readable before that — what it is.
    ///
    /// `details` is false once the model and manufacturer are already known: the
    /// setup window re-checks the cable every second and a half, and there is no
    /// reason to make three adb round trips where one answers the only question
    /// still being asked, which is whether the device is still there.
    static func probe(details: Bool = true) -> CableState {
        guard FileManager.default.isExecutableFile(atPath: Config.adb) else { return .adbMissing }
        let (_, out) = Shell.run(Config.adb, ["devices", "-l"])
        let state = parse(devicesOutput: out)
        guard details, case .ready(var found) = state else { return state }
        found.model = property(found.serial, "ro.product.model")
        found.manufacturer = property(found.serial, "ro.product.manufacturer")
        return .ready(found)
    }

    static func property(_ serial: String, _ name: String) -> String {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell", "getprop \(name)"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading the device's addresses

    /// The device's own Wi-Fi address, pulled off the cable so nobody has to go
    /// hunting through Settings for it.
    static func parseWifiAddress(from routeOutput: String) -> String? {
        for line in routeOutput.split(separator: "\n") where line.contains("wlan0") {
            let fields = line.split(separator: " ").map(String.init)
            if let i = fields.firstIndex(of: "src"), i + 1 < fields.count {
                return fields[i + 1]
            }
        }
        return nil
    }

    /// The device's Tailscale address, if Tailscale is running on it.
    ///
    /// Not available from `ip route` the way the Wi-Fi one is: Tailscale on
    /// Android is a VPN interface, so its address has to be read from the
    /// interface list. Anything in 100.64.0.0/10 — the range Tailscale assigns
    /// from — is one, and nothing else on a phone uses that range.
    static func parseTailscaleAddress(from addrOutput: String) -> String? {
        for line in addrOutput.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard let i = fields.firstIndex(of: "inet"), i + 1 < fields.count else { continue }
            let address = fields[i + 1].split(separator: "/").map(String.init)[0]
            let octets = address.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) else { continue }
            return address
        }
        return nil
    }

    static func wifiAddress(_ serial: String) -> String? {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell", "ip route"])
        return parseWifiAddress(from: out)
    }

    static func tailscaleAddress(_ serial: String) -> String? {
        let (_, out) = Shell.run(Config.adb, ["-s", serial, "shell", "ip -4 addr show"])
        return parseTailscaleAddress(from: out)
    }

    /// Switches the device to wireless debugging on the pinned port, which is
    /// what lets the cable come out and never go back in.
    static func enableWirelessDebugging(_ serial: String, port: String = "5555") {
        Shell.log("switching \(serial) to wireless debugging on port \(port)")
        Shell.run(Config.adb, ["-s", serial, "tcpip", port])
        Shell.pause(3.0)
    }

    /// Proves the device actually answers on the address about to be written,
    /// while the cable is still attached to fix it if it does not.
    ///
    /// Worth the two seconds: everything up to here can succeed and still leave
    /// a config that does not work — a Tailscale address typed with a digit
    /// wrong, or a device whose wireless debugging did not come up. Finding that
    /// out now, with the cable in hand, is the whole difference between "saved"
    /// and "working".
    static func verifyWireless(host: String, port: String = "5555") -> Bool {
        let target = "\(host):\(port)"
        Shell.run(Config.adb, ["disconnect", target])
        Shell.run(Config.adb, ["connect", target])
        Shell.pause(1.5)
        let (_, out) = Shell.run(Config.adb, ["devices"])
        let ok = out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                            .map(String.init).filter { !$0.isEmpty }
            return parts.count >= 2 && parts[0] == target && parts[1] == "device"
        }
        Shell.log("setup verified \(target): \(ok ? "answers" : "no answer")")
        return ok
    }

    // MARK: Naming

    /// A short id from the model, for the `mirror <id>` command. Letters and
    /// digits only, because it is typed at a shell prompt and lands in a
    /// preferences key.
    static func suggestedID(for found: Found, taken: [String]) -> String {
        let cleaned = found.model.lowercased().filter { $0.isLetter || $0.isNumber }
        var base = String(cleaned.prefix(10))
        if base.isEmpty { base = "phone" }
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// The rules the id has to satisfy, phrased as the reason it does not, so
    /// the window can say what is wrong rather than just refusing.
    static func idProblem(_ id: String, taken: [String]) -> String? {
        if id.isEmpty { return "Give it a short name to type after `mirror`." }
        if !id.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return "Letters and digits only — it gets typed at a terminal prompt."
        }
        if taken.contains(id) { return "You already have a device called \"\(id)\"." }
        return nil
    }

    // MARK: Writing devices.json

    /// Adds (or replaces) a device in the same file the CLI reads and writes.
    ///
    /// The written shape has to match `mirror add` exactly — same keys, same
    /// defaults — because both programs read this file and a field only one of
    /// them writes is a field the other silently treats as absent.
    static func save(id: String,
                     name: String,
                     host: String,
                     isTablet: Bool,
                     found: Found) throws {
        let path = Device.configPath
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var entry: [String: Any] = [
            "id": id,
            "name": name,
            "host": host,
            "port": 5555,
            "title": name,
            "kind": isTablet ? "tablet" : "phone",
            // Enough of the model string to recognise the device on USB later,
            // without pinning it to one exact variant.
            "usbModelPrefixes": found.model.isEmpty ? [] : [String(found.model.prefix(6))],
            "screenOffBreaksCapture": false,
            // Samsung's keyguard behaves differently enough to be worth
            // special-casing; everything else gets the generic path.
            "unlockStyle": found.isSamsung ? "samsung" : "generic",
        ]
        // A device with no address is a USB-only one, and an empty string would
        // read as "reach it at :5555" rather than "there is no address".
        if host.isEmpty { entry.removeValue(forKey: "host") }

        var devices = root["devices"] as? [[String: Any]] ?? []
        devices.removeAll { ($0["id"] as? String) == id }
        devices.append(entry)
        root["devices"] = devices
        if root["notify"] == nil { root["notify"] = ["enabled": false] }

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        // Written beside the target and moved into place, so an interrupted
        // write cannot leave the file half-replaced — the CLI does the same.
        let temp = URL(fileURLWithPath: path + ".tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        Shell.log("setup wrote device \(id) to \(path)")
        // Deliberately does not reload Device.all here. This runs on a detached
        // task, and that list is read by the menu on the main actor — so the
        // caller reloads once it is back there.
    }
}
