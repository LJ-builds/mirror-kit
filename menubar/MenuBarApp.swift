import AppKit

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    /// State of every device, so the menu can show at a glance which ones are up
    /// without blocking on adb while it's being drawn.
    var states: [String: MirrorState] = [:]
    var busy: Bool = false
    var busyLabel: String = ""
    /// Remembered per device so a restart triggered by an option toggle preserves
    /// the screen the mirror was actually started on — the physical panel, with
    /// or without it lit, or the separate virtual one.
    var lastScreen: [String: Mirror.Screen] = [:]
    /// Devices whose sound is being forwarded right now. Polled rather than
    /// assumed, because the audio stream is its own process and can end without
    /// the menu having asked it to.
    var streamingAudio: [String: Bool] = [:]
    /// Devices whose mirror is up but blacked out behind a PIN prompt.
    var lockedMidMirror: Set<String> = []
    /// Guards against the 6s poll stacking a new PIN dialog on every tick.
    var promptingPin = false
    /// Devices whose PIN prompt the user dismissed. Cleared when the phone is
    /// seen unlocked again, so declining once doesn't mean never asking again —
    /// it means not asking again about *this* lock.
    var pinDeclined: Set<String> = []
    /// Which devices currently have a keyboard-only session attached. Polled
    /// alongside mirror state so the menu's checkmark survives app restarts and
    /// notices a session closed from its own window.
    var keyboardOnly: [String: Bool] = [:]
    /// True while a mirror session is running that *we* unlocked — those devices
    /// get locked back when their mirror stops, and left alone otherwise.
    var autoUnlocked: [String: Bool] = [:]

    var device: Device { Selection.current }
    var state: MirrorState { states[device.id] ?? .unreachable }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Say what was loaded and from where. When someone's device does not
        // appear, this line is the difference between "the config is wrong" and
        // "the app is broken", and it is the first thing to ask them for.
        if Device.all.isEmpty {
            Shell.log("no devices in \(Device.configPath) — opening the setup window")
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

        // A fresh install has nothing configured, and a menu bar icon with an
        // empty menu is not an invitation. Open the way in instead — this is the
        // first thing anyone sees after installing, so it should be the thing
        // that sets them up rather than a note about where to go next.
        if Device.all.isEmpty {
            OnboardingWindow.shared.show()
        }

        // Poll so the icon reflects reality even when the menu is closed.
        timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: State

    func refreshState() {
        guard !busy else { return }
        refreshStateForced()
    }

    /// Not every SF Symbol exists on every macOS version, and a nil image leaves
    /// the menu bar item invisible — so fall back down a list.
    func symbol(_ names: [String], _ description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image
            }
        }
        return nil
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let label = state.label(for: device)
        let names = busy ? ["circle.dotted", "circle"] : state.symbolNames(for: device)
        let image = symbol(names, label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = busy ? busyLabel : "\(device.menuName) — \(label)"
    }

    func setBusy(_ label: String) {
        busy = true
        busyLabel = label
        updateIcon()
    }

    func clearBusy() {
        busy = false
        busyLabel = ""
        refreshStateForced()
    }

    func refreshStateForced() {
        Task.detached {
            var polled: [String: MirrorState] = [:]
            var keys: [String: Bool] = [:]
            var sound: [String: Bool] = [:]
            for device in Device.all {
                polled[device.id] = Mirror.currentState(device)
                keys[device.id] = KeyboardOnly.isRunning(device)
                sound[device.id] = Mirror.isStreamingAudio(device)
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
            //
            // A device configured `unlockStyle: none` is skipped entirely: its
            // owner said the lock screen is not this app's business, and noticing
            // it here is the first step of a path that ends in an unasked-for PIN
            // dialog every six seconds.
            var lockedNow: [String] = []
            for device in Device.all
            where polled[device.id] == .mirroring && device.handlesKeyguard {
                if let link = Mirror.currentLink(device), Keyguard.isLocked(link.serial) {
                    lockedNow.append(device.id)
                }
            }

            let fresh = polled   // immutable copies: the closure below crosses actors
            let freshKeys = keys
            let freshSound = sound
            let locked = Set(lockedNow)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.states = fresh
                self.keyboardOnly = freshKeys
                self.streamingAudio = freshSound
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
}
