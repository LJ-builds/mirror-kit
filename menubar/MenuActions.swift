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

    @objc func startMirror() { beginStart(screen: .physical(screenOff: false)) }
    @objc func startMirrorScreenOff() { beginStart(screen: .physical(screenOff: true)) }
    @objc func startMirrorVirtual() { beginStart(screen: .separate) }

    func beginStart(screen: Mirror.Screen) {
        let device = self.device
        lastScreen[device.id] = screen
        setBusy("Connecting…")
        Task.detached {
            let connected = Mirror.connect(device)
            if !connected {
                await MainActor.run { [weak self] in
                    self?.clearBusy()
                    self?.promptForPort(device, thenStart: screen)
                }
                return
            }

            // Capture sits behind the keyguard, so clear it before opening a
            // window onto a lockscreen that would just render black. Waking the
            // phone is fine *here* — the user asked for a mirror a moment ago.
            // It is only the background poll that must never do this, because
            // there the same wake repeats forever on a timer.
            //
            // Neither applies to the separate virtual screen: it is not behind
            // the keyguard at all, and the whole point of the mode is to leave
            // the device's own panel alone.
            if case .physical = screen, device.handlesKeyguard,
               let link = Mirror.currentLink(device),
               Keyguard.isLocked(link.serial) {
                if Keyguard.isPocketGuarded(device, link.serial) {
                    await MainActor.run { [weak self] in
                        self?.clearBusy()
                        self?.alert(Self.pocketGuardMessage(device),
                                    Self.pocketGuardDetail)
                    }
                    return
                }
                // A swipe-only keyguard falls away here and never needs a PIN.
                if !Keyguard.tryUnlockWithoutPin(device, link.serial) {
                    // Needs the PIN. It is asked for every time and never stored,
                    // so hand back to the main actor to prompt.
                    await MainActor.run { [weak self] in
                        self?.clearBusy()
                        self?.promptForPin(device, thenStart: screen)
                    }
                    return
                }
                Shell.log("\(device.id) unlocked (no PIN needed) for physical mirror")
                await MainActor.run { [weak self] in self?.autoUnlocked[device.id] = true }
            }

            Mirror.start(device, screen: screen)
            Shell.pause(4.0)

            // A stale device-side server can eat the first attach; retry once.
            if !Mirror.isMirroring(device) {
                Shell.log("first attach failed for \(device.id), retrying")
                Shell.run(Config.adb, ["disconnect", device.target])
                Shell.run(Config.adb, ["connect", device.target])
                Shell.pause(2.0)
                Mirror.start(device, screen: screen)
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
                if !ok { self?.promptForPort(device, thenStart: nil) }
            }
        }
    }

    /// After a device reboot the port is randomized. Ask for the new one, re-pin 5555,
    /// and optionally continue into starting the mirror.
    func promptForPort(_ device: Device, thenStart screen: Mirror.Screen?) {
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
                } else if let screen {
                    self.beginStart(screen: screen)
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
        promptForPin(device, thenStart: nil)
    }

    /// The device demanded a PIN. It is asked for on every unlock and never
    /// written to disk, so this runs each time rather than once.
    ///
    /// `screen` nil means the mirror is already running and only the keyguard
    /// is in the way — typing the PIN here is the whole point, since the bouncer
    /// is a secure window and shows up in the mirror as an unreadable black
    /// rectangle. Nothing is restarted in that case; the picture comes back by
    /// itself the moment the phone unlocks.
    func promptForPin(_ device: Device, thenStart screen: Mirror.Screen?) {
        // A device configured `unlockStyle: none` has said its lock screen is not
        // this app's business. Nothing in the menu leads here for one, but the
        // guard belongs at the door rather than only on the paths that reach it.
        guard device.handlesKeyguard else { return }
        promptingPin = true
        defer { promptingPin = false }

        let alert = NSAlert()
        alert.messageText = "Unlock the \(device.menuName)"
        alert.informativeText = screen == nil
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
        alert.addButton(withTitle: screen == nil ? "Unlock" : "Unlock & Mirror")
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
            let result = Keyguard.unlock(device: device, serial: link.serial, pin: pin)
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
                    if let screen { self.beginStart(screen: screen) }
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
                case .notOurs:
                    break   // configured `unlockStyle: none`; nothing was touched
                }
            }
        }
    }

    @objc func unlockNow() {
        promptForPin(device, thenStart: nil)
    }

    @objc func toggleCursor() {
        let device = self.device
        Prefs.setDeviceCursor(device, !Prefs.deviceCursor(device))
        // A pointer drawn on a dark screen is useless, so the two modes are
        // mutually exclusive: enabling the cursor drops screen-off.
        if Prefs.deviceCursor(device), case .physical(true)? = lastScreen[device.id] {
            lastScreen[device.id] = .physical(screenOff: false)
        }
        restartVideoIfMirroring()
    }

    @objc func toggleKeyboard() {
        let device = self.device
        Prefs.setUhidKeyboard(device, !Prefs.uhidKeyboard(device))
        restartVideoIfMirroring()
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
                        self?.promptForPort(device, thenStart: nil)
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

    /// Sound has its own scrcpy process, which is what makes turning it *off* a
    /// live switch: the stream stops, the device gets its playback back at once,
    /// and the picture never flickers. That is `mirror <id> hush` in a menu item.
    ///
    /// Turning it on is the asymmetric half. Audio and video have to be buffered
    /// by the same number of milliseconds or the sound simply plays late, and
    /// that buffer is fixed when scrcpy launches — so switching sound on has to
    /// relaunch the picture, and switching it off never does.
    @objc func toggleAudio() {
        let device = self.device
        let wantOn = !Prefs.streamAudio(device)
        Prefs.setStreamAudio(device, wantOn)
        guard state == .mirroring else { return }   // applies at the next start
        if wantOn {
            restartAllIfMirroring()
        } else {
            setBusy("Handing sound back…")
            Task.detached {
                Mirror.stopAudio(device)
                await MainActor.run { [weak self] in self?.clearBusy() }
            }
        }
    }

    /// The one toggle that changes the shared buffer, so it is the one that has
    /// to take the sound down with the picture.
    @objc func toggleWatchMode() {
        let device = self.device
        Prefs.setWatchMode(device, !Prefs.watchMode(device))
        restartAllIfMirroring()
    }

    @objc func selectFrugal() {
        let device = self.device
        guard Prefs.sharpVideo(device) || !Prefs.frugalVideo(device) else { return }
        Prefs.setSharpVideo(device, false)
        Prefs.setFrugalVideo(device, true)
        restartVideoIfMirroring()
    }

    @objc func selectSmooth() {
        let device = self.device
        guard Prefs.sharpVideo(device) || Prefs.frugalVideo(device) else { return }
        Prefs.setSharpVideo(device, false)
        Prefs.setFrugalVideo(device, false)
        restartVideoIfMirroring()
    }

    @objc func selectSharp() {
        let device = self.device
        guard !Prefs.sharpVideo(device) else { return }
        Prefs.setSharpVideo(device, true)
        restartVideoIfMirroring()
    }

    /// Rotation is a device setting, so it applies live — no restart needed.
    @objc func toggleLandscape() {
        let device = self.device
        let on = !Prefs.forceLandscape(device)
        Prefs.setForceLandscape(device, on)
        Task.detached { Mirror.setLandscape(device, on) }
    }

    /// Quality, cursor and keyboard are all fixed at scrcpy launch, so a live
    /// mirror has to be relaunched for any of them to take effect — but none of
    /// them mean anything to the sound, which runs as its own process and is
    /// left alone. Nothing plays out of the phone in the gap, so there is no
    /// volume dance to do around it.
    func restartVideoIfMirroring() {
        guard state == .mirroring else { return }
        let device = self.device
        let screen = lastScreen[device.id] ?? .physical(screenOff: false)
        setBusy("Restarting…")
        Task.detached {
            Mirror.stopVideo(device)
            Shell.pause(2.0)
            Mirror.start(device, screen: screen)
            Shell.pause(4.0)
            await MainActor.run { [weak self] in self?.clearBusy() }
        }
    }

    /// The heavier restart, for the two changes that alter the buffer both
    /// streams share. Here the sound really does come down with the picture, so
    /// the device is silenced across the gap — otherwise the seconds between
    /// sessions play out of the phone's own speaker, in whatever room it is in,
    /// at the volume raised for capture.
    func restartAllIfMirroring() {
        guard state == .mirroring else { return }
        let device = self.device
        let screen = lastScreen[device.id] ?? .physical(screenOff: false)
        setBusy("Restarting…")
        Task.detached {
            Mirror.silenceAcrossRestart(device)
            Mirror.stop(device, restoreVolume: false)
            Shell.pause(2.0)
            Mirror.start(device, screen: screen)   // raises volume once up
            Mirror.resumeAfterRestart(device)
            Shell.pause(4.0)
            await MainActor.run { [weak self] in self?.clearBusy() }
        }
    }

    @objc func openOnboarding() {
        OnboardingWindow.shared.show()
    }

    @objc func toggleLoginItem() {
        LoginItem.set(!LoginItem.isEnabled)
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
