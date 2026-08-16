// What each menu item does. Everything here runs off the main actor for the
// adb round trips, which take seconds, and hops back to update the UI.

import AppKit

extension AppDelegate {
    // MARK: Actions

    /// Switching device is just a preference flip; nothing is started or stopped,
    /// so a mirror already running on the other device keeps running.
    @objc func selectDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let picked = Device.all.first(where: { $0.id == id }),
              picked.id != device.id else { return }
        Selection.current = picked
        updateIcon()
        refreshStateForced()
    }

    @objc func startMirror() { beginStart(screenOff: false) }
    @objc func startMirrorScreenOff() { beginStart(screenOff: true) }

    func beginStart(screenOff: Bool) {
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

    @objc func stopMirror() {
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

    @objc func reconnectTablet() {
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
    func promptForPort(_ device: Device, thenStartScreenOff screenOff: Bool?) {
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
    func promptForPinIfIdle(_ device: Device) {
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
    func promptForPin(_ device: Device, thenStartScreenOff screenOff: Bool?) {
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

    @objc func unlockNow() {
        promptForPin(device, thenStartScreenOff: nil)
    }

    @objc func toggleCursor() {
        let device = self.device
        Prefs.setDeviceCursor(device, !Prefs.deviceCursor(device))
        // A pointer drawn on a dark screen is useless, so the two modes are
        // mutually exclusive: enabling the cursor drops screen-off.
        if Prefs.deviceCursor(device) { lastScreenOff[device.id] = false }
        restartIfMirroring()
    }

    @objc func toggleKeyboard() {
        let device = self.device
        Prefs.setUhidKeyboard(device, !Prefs.uhidKeyboard(device))
        restartIfMirroring()
    }

    /// Starts or stops the keyboard-only session. It is deliberately independent
    /// of the mirror: both can run at once, and stopping one leaves the other.
    @objc func toggleKeyboardOnly() {
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

    @objc func toggleAudio() {
        let device = self.device
        Prefs.setStreamAudio(device, !Prefs.streamAudio(device))
        restartIfMirroring()
    }

    @objc func toggleWatchMode() {
        let device = self.device
        Prefs.setWatchMode(device, !Prefs.watchMode(device))
        restartIfMirroring()
    }

    @objc func selectFrugal() {
        let device = self.device
        guard Prefs.sharpVideo(device) || !Prefs.frugalVideo(device) else { return }
        Prefs.setSharpVideo(device, false)
        Prefs.setFrugalVideo(device, true)
        restartIfMirroring()
    }

    @objc func selectSmooth() {
        let device = self.device
        guard Prefs.sharpVideo(device) || Prefs.frugalVideo(device) else { return }
        Prefs.setSharpVideo(device, false)
        Prefs.setFrugalVideo(device, false)
        restartIfMirroring()
    }

    @objc func selectSharp() {
        let device = self.device
        guard !Prefs.sharpVideo(device) else { return }
        Prefs.setSharpVideo(device, true)
        restartIfMirroring()
    }

    /// Rotation is a device setting, so it applies live — no restart needed.
    @objc func toggleLandscape() {
        let device = self.device
        let on = !Prefs.forceLandscape(device)
        Prefs.setForceLandscape(device, on)
        Task.detached { Mirror.setLandscape(device, on) }
    }

    /// Input mode is fixed at scrcpy launch, so a live mirror has to be relaunched
    /// for a toggle to take effect.
    func restartIfMirroring() {
        guard state == .mirroring else { return }
        let device = self.device
        setBusy("Restarting…")
        let keepScreenOff = lastScreenOff[device.id] ?? false
        Task.detached {
            Mirror.silenceAcrossRestart(device)
            Mirror.stop(device, restoreVolume: false)
            Shell.pause(2.0)
            Mirror.start(device, screenOff: keepScreenOff)   // raises volume once up
            Mirror.resumeAfterRestart(device)
            Shell.pause(4.0)
            await MainActor.run { [weak self] in self?.clearBusy() }
        }
    }

    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: Config.logPath) {
            FileManager.default.createFile(atPath: Config.logPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.logPath))
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
