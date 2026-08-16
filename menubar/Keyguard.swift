import AppKit

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
        /// The device is configured `unlockStyle: none`, so nothing was tried.
        /// Reaching this is a bug in the caller — the UI that leads here is not
        /// offered for such a device — but it fails silently rather than waking
        /// a phone whose owner asked for exactly the opposite.
        case notOurs
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
    ///
    /// Only One UI has the window this looks for, so anything else is answered
    /// without an adb round trip that could only ever come back false.
    static func isPocketGuarded(_ device: Device, _ serial: String) -> Bool {
        guard device.hasPocketGuard else { return false }
        return focusedWindow(serial).contains("UnintentionalLcdOn")
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
    ///
    /// Refuses outright for `unlockStyle: none`: that setting means the lock
    /// screen is the user's business, and honouring it only at the call sites
    /// would leave this one waking devices that asked to be left alone.
    static func unlock(device: Device, serial: String, pin: String) -> Result {
        guard device.handlesKeyguard else { return .notOurs }
        if isPocketGuarded(device, serial) { return .coveredByPocketGuard }
        guard wakeAndDismiss(serial) else { return .unlocked }
        if isPocketGuarded(device, serial) { return .coveredByPocketGuard }
        guard waitForPrompt(serial) else {
            return isPocketGuarded(device, serial) ? .coveredByPocketGuard : .promptNeverAppeared
        }
        return enterPin(serial, pin) ? .unlocked : .pinRejected
    }

    /// Wake + dismiss only, for the case where no PIN is required at all.
    /// Returns true if that alone got the device unlocked.
    static func tryUnlockWithoutPin(_ device: Device, _ serial: String) -> Bool {
        guard device.handlesKeyguard else { return false }
        return !wakeAndDismiss(serial)
    }
}
