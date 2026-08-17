import AppKit

// MARK: - Mirror control

/// How we're talking to the tablet. USB has far more bandwidth than Wi-Fi, so it
/// gets the smooth profile without asking.
struct Link {
    let serial: String
    let isUSB: Bool
}

struct Mirror {
    /// Which screen a session is showing.
    enum Screen {
        /// The device's own panel. Display 0 is the cover screen while a foldable
        /// is shut and the inner one once it is opened, and scrcpy follows that
        /// switch, so there is nothing to choose between.
        case physical(screenOff: Bool)
        /// A separate screen the device itself never shows. Works while it is
        /// folded shut or locked, and leaves whatever is on the real panel alone.
        /// Needs "virtualDisplay" configured; the CLI calls this mode `big`.
        case separate
    }

    /// What a running `scrcpy -s <serial>` was started to do.
    ///
    /// Told apart by flags rather than by a marker each session has to remember
    /// to carry — an earlier version keyed the mirror to `--stay-awake`, which
    /// meant any new mode silently became invisible to `isMirroring` and
    /// unstoppable by `stop` the moment it had a reason not to pass that flag.
    /// Video is the thing a mirror has and the other two do not; of the two
    /// videoless sessions, the keyboard is the one that also refuses audio.
    enum Session {
        case mirror
        case audio
        case keyboard

        init(commandLine: String) {
            guard commandLine.contains("--no-video") else { self = .mirror; return }
            self = commandLine.contains("--no-audio") ? .keyboard : .audio
        }
    }

    // MARK: Finding sessions

    /// Every scrcpy this device has running, as (pid, kind). Matched on
    /// `-s <serial>` alone, so a session started with flags nothing here
    /// anticipated is still found and still stoppable.
    static func sessions(_ device: Device) -> [(pid: Int32, kind: Session)] {
        var found: [(pid: Int32, kind: Session)] = []
        for serial in knownSerials(device) {
            // -l alongside -f prints the pid and the whole argument list, which
            // is what the classification above reads.
            let (_, out) = Shell.run("/usr/bin/pgrep", ["-lf", "scrcpy -s \(serial) "])
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
                found.append((pid, Session(commandLine: String(parts[1]))))
            }
        }
        return found
    }

    static func pids(_ device: Device, _ kind: Session) -> [Int32] {
        sessions(device).filter { $0.kind == kind }.map(\.pid)
    }

    /// Plain SIGTERM, never SIGKILL: a killed scrcpy never sends the touch-up
    /// matching a gesture in flight, and Android then leaves that pointer down
    /// forever — after which every injected touch is rejected and the mirror
    /// looks alive but ignores the trackpad.
    static func terminate(_ pids: [Int32]) {
        for pid in pids { kill(pid, SIGTERM) }
    }

    static func isMirroring(_ device: Device) -> Bool {
        !pids(device, .mirror).isEmpty
    }

    /// True while the detachable sound stream is up, which is what makes the
    /// menu's audio item a live switch rather than a setting for next time.
    static func isStreamingAudio(_ device: Device) -> Bool {
        !pids(device, .audio).isEmpty
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

    // MARK: Connecting

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

    // MARK: Picture quality

    /// USB always gets Smooth. On Wi-Fi it's the user's choice.
    static func useSmooth(for link: Link, _ device: Device) -> Bool {
        link.isUSB ? true : !Prefs.sharpVideo(device)
    }

    /// The size cap, kept apart from the codec settings because the separate
    /// virtual screen wants the second and not the first: its "WxH/dpi" already
    /// fixes the size, and a second limit on top would only downscale what was
    /// explicitly asked for.
    ///
    /// The same three tiers and the same numbers as the CLI's `frugal` / `medium`
    /// / `sharp`, so one device does not look different depending on which front
    /// door started it. "maxSize" in devices.json overrides the tier's width.
    static func sizeArgs(for link: Link, _ device: Device) -> [String] {
        if let explicit = device.maxSize { return ["-m", String(explicit)] }
        if link.isUSB { return ["-m", "1920"] }
        if Prefs.sharpVideo(device) { return ["-m", "0"] }   // 0 is scrcpy's "no limit"
        return ["-m", Prefs.frugalVideo(device) ? "800" : "1024"]
    }

    static func codecArgs(for link: Link, _ device: Device) -> [String] {
        if link.isUSB {
            // USB has bandwidth to spare, so spend it on pixels and quality.
            return ["--video-codec=h265", "-b", "16M"]
        }
        if Prefs.sharpVideo(device) {
            // Full panel, no downscaling. Sharper, fewer frames.
            return ["-b", "24M"]
        }
        // Over Wi-Fi the enemy is latency, not bandwidth: H.265 costs real
        // encode time on the phone, and every extra pixel is another frame's
        // worth of delay on a jittery link. H.264 at 1024/6M/60fps measurably
        // improved how the mirror felt on the fold (2026-08-15); 800/4M is
        // the frugal step down from that, chosen to save mobile data.
        return ["--video-codec=h264",
                "-b", Prefs.frugalVideo(device) ? "4M" : "6M",
                "--max-fps=60"]
    }

    /// Jitter buffering, console-streaming style. scrcpy ships with none on video
    /// and only 50ms on audio, so every jitter spike is a visible hitch or an
    /// audible crackle. The two numbers must match: video buffering is what keeps
    /// the picture level with the sound, and leaving video at 0 while audio waits
    /// 120ms is lip-sync error, not responsiveness.
    ///
    /// Watch Mode buffers half a second. That is a lot by remote-control standards
    /// and the whole point: when nobody is pointing at anything, latency is free,
    /// and a deeper pool rides out the jitter spikes that a shallow one only
    /// postpones.
    static func bufferMs(_ device: Device) -> Int {
        if Prefs.watchMode(device) { return 500 }
        return Prefs.streamAudio(device) ? 120 : 0
    }

    // MARK: Starting and stopping

    static func start(_ device: Device, screen: Screen) {
        guard let link = currentLink(device) else {
            Shell.log("start aborted: \(device.id) not connected")
            return
        }
        // Rotating is done to the device itself, so it belongs only to the mode
        // that shows the device itself. The separate screen has its own shape
        // from "virtualDisplay", and turning the real panel sideways for it would
        // be the one thing this mode promises not to do.
        if case .physical = screen, Prefs.forceLandscape(device) {
            setLandscape(device, true)
        }

        var args = [
            "-s", link.serial,
            // Reverse tunnelling fails intermittently over network adb
            // ("Server connection failed"); forward is reliable.
            "--force-adb-forward",
            // Where files dragged onto the window land.
            "--push-target=\(device.pushTarget)",
            // Sound is a separate process (see startAudio), so this one never
            // carries it — it only buffers video to stay level with that stream.
            "--no-audio",
        ]
        args.append(contentsOf: codecArgs(for: link, device))

        switch screen {
        case .physical(let screenOff):
            args.append(contentsOf: sizeArgs(for: link, device))
            args.append(contentsOf: ["--display-id=0", "--stay-awake",
                                     "--window-title", device.windowTitle])
            if screenOff && !device.screenOffBreaksCapture { args.append("--turn-screen-off") }
        case .separate:
            // No --stay-awake: the point of this mode is to leave the device's
            // own panel to do whatever it was doing, sleeping included.
            args.append(contentsOf: [
                "--new-display=\(device.virtualDisplay)",
                "--no-vd-destroy-content",   // leave apps running there when the window closes
                "--window-title", "\(device.windowTitle) (virtual)",
            ])
        }

        let buffer = bufferMs(device)
        if buffer > 0 { args.append("--video-buffer=\(buffer)") }
        if Prefs.deviceCursor(device) { args.append("--mouse=uhid") }
        if Prefs.uhidKeyboard(device) { args.append("--keyboard=uhid") }

        // adb push will not create a missing destination directory, so a drop
        // into a folder that doesn't exist yet fails with no visible error.
        Shell.run(Config.adb, ["-s", link.serial, "shell",
                               "mkdir -p '\(device.pushTarget)'"])

        Shell.log("starting \(device.id) mirror (link=\(link.isUSB ? "USB" : "wifi"), "
                  + "screen=\(screen.logName), "
                  + "audio=\(Prefs.streamAudio(device)), "
                  + "profile=\(useSmooth(for: link, device) ? "smooth" : "sharp"), "
                  + "cursor=\(Prefs.deviceCursor(device)), uhidKbd=\(Prefs.uhidKeyboard(device)))")
        Shell.launchDetached(Config.scrcpy, args)

        if Prefs.streamAudio(device) { startAudio(device) }
    }

    /// Stops this device's mirror and its sound, leaving any other device — and
    /// any keyboard-only session on this one — running.
    static func stop(_ device: Device, restoreVolume: Bool = true) {
        terminate(pids(device, .mirror))
        stopAudio(device, restoreVolume: restoreVolume)
        // Hand the device back in a normal state for hand-held use.
        if Prefs.forceLandscape(device) { setLandscape(device, false) }
        Shell.log("\(device.id) mirror stopped")
    }

    /// Stops only the picture, leaving the sound stream running. Most of the
    /// options that force a relaunch — the quality tier, the cursor, the keyboard
    /// — are fixed at scrcpy launch but mean nothing to audio, so the sound has
    /// no reason to be interrupted. While it is not, nothing comes out of the
    /// phone's own speaker and there is no gap to paper over.
    static func stopVideo(_ device: Device) {
        terminate(pids(device, .mirror))
    }

    /// Silences the device across a restart that genuinely has to take the sound
    /// down too — which, now that audio is its own process, means only a change
    /// to the buffer both streams share. The moment that process dies Android
    /// hands playback back to the phone's own speaker, so the couple of seconds
    /// between sessions come out loud, in whatever room the phone is in, at the
    /// volume this app raised for capture.
    static func silenceAcrossRestart(_ device: Device) {
        guard isStreamingAudio(device), let link = currentLink(device) else { return }
        if let found = mediaVolume(link.serial), found < maxMediaVolume {
            rememberVolume(device.id, found)      // remember the human's level
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

    // MARK: Sound

    /// The sound runs as its own scrcpy process, exactly as the CLI does it, and
    /// that is what makes it detachable: killing this one releases Android's
    /// playback capture without touching the video stream or the adb connection.
    /// It also means a restart for a quality change no longer interrupts the
    /// audio at all, so nothing has to mute the phone across the gap any more.
    static func startAudio(_ device: Device) {
        guard let link = currentLink(device) else { return }
        guard !isStreamingAudio(device) else { return }

        Shell.log("starting \(device.id) audio stream (buffer=\(bufferMs(device))ms)")
        Shell.launchDetached(Config.scrcpy, [
            "-s", link.serial,
            "--no-video", "--no-window",
            "--audio-bit-rate=192K",
            "--audio-buffer=\(bufferMs(device))",
            "--force-adb-forward",
        ])

        // Turn the capture gain up only *after* scrcpy has taken playback away
        // from the device. Doing it before launch — as this did at first — means
        // the phone spends the second or two of startup playing out of its own
        // speaker at maximum volume, which is a genuine jump scare.
        Shell.pause(3.0)
        guard isStreamingAudio(device) else { return }
        guard let found = mediaVolume(link.serial), found < maxMediaVolume else { return }
        // Putting the level aside no-ops when one is already held, and the gain
        // goes up either way. The two are deliberately not one condition: across
        // a restart the level found here is the zero this app itself set, so
        // saving it would hand the device back permanently muted — but skipping
        // the raise on that account would leave the Mac receiving silence.
        rememberVolume(device.id, found)
        setMediaVolume(link.serial, maxMediaVolume)
        Shell.log("\(device.id) media volume \(found) → \(maxMediaVolume) for capture gain")
    }

    /// Hands the sound straight back to the device without disturbing the mirror
    /// — the same thing `mirror <id> hush` does from a terminal.
    static func stopAudio(_ device: Device, restoreVolume: Bool = true) {
        let running = pids(device, .audio)
        terminate(running)
        if !running.isEmpty { Shell.log("\(device.id) audio stream stopped") }
        // The link is checked before the level is taken, not after: if the device
        // has gone offline there is nothing to set it on, and consuming the
        // remembered level anyway would lose it for good.
        guard restoreVolume, let link = currentLink(device),
              let level = takeSavedVolume(device.id) else { return }
        // Put the human's level back as Android hands playback over, so the first
        // thing out of the speaker is not at capture gain.
        setMediaVolume(link.serial, level)
        Shell.log("\(device.id) media volume restored to \(level)")
    }

    // MARK: Media volume

    /// The default audio source forwards the post-volume mix and silences the
    /// phone's own speaker, so the device's media volume is really the *gain* on
    /// what the Mac receives. Left at a normal listening level it hands the Mac
    /// a weak signal that then has to be amplified, hiss and all. Turned up it
    /// costs nothing, because the phone itself stays silent while forwarding.
    ///
    /// The level found is put aside so it can go back afterwards — otherwise the
    /// next notification after the sound stops arrives at full blast.
    static let maxMediaVolume = 15

    /// Levels to hand back, keyed by device id. Reached from several detached
    /// tasks at once — a start, a stop, and a poll can all be in flight — so it
    /// is behind a lock rather than an `unsafe` annotation that only tells the
    /// compiler to stop asking.
    private static let volumeLock = NSLock()
    nonisolated(unsafe) private static var savedVolumes: [String: Int] = [:]

    private static func withVolumes<T>(_ body: (inout [String: Int]) -> T) -> T {
        volumeLock.lock()
        defer { volumeLock.unlock() }
        return body(&savedVolumes)
    }

    /// Stores `level` only if nothing is remembered yet, and says whether it took.
    /// Checking and setting have to be one step: the level found during a restart
    /// is the one this app itself raised, and saving that over the human's would
    /// hand the device back permanently at capture gain.
    @discardableResult
    static func rememberVolume(_ id: String, _ level: Int) -> Bool {
        withVolumes { volumes in
            guard volumes[id] == nil else { return false }
            volumes[id] = level
            return true
        }
    }

    static func takeSavedVolume(_ id: String) -> Int? {
        withVolumes { $0.removeValue(forKey: id) }
    }

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

    // MARK: Orientation

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

extension Mirror.Screen {
    var logName: String {
        switch self {
        case .physical(let screenOff): return screenOff ? "physical/screen-off" : "physical"
        case .separate:                return "virtual"
        }
    }
}
