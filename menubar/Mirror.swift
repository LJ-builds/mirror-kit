import AppKit

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
        // Volume alone does not settle it: Android appears to restore its own
        // remembered level as it releases the capture, so setting zero first
        // only wins part of the gap — quieter, still audible. Pausing is the
        // deterministic version of the same intent. Nothing playing, nothing to
        // leak, and the track picks up where it left off.
        Shell.run(Config.adb, ["-s", link.serial, "shell",
                               "input keyevent KEYCODE_MEDIA_PAUSE"])
    }

    /// Undoes `silenceAcrossRestart`, once the new session is actually carrying
    /// audio — resuming earlier just moves the leak later.
    static func resumeAfterRestart(_ device: Device) {
        guard Prefs.streamAudio(device), let link = currentLink(device) else { return }
        Shell.run(Config.adb, ["-s", link.serial, "shell",
                               "input keyevent KEYCODE_MEDIA_PLAY"])
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
