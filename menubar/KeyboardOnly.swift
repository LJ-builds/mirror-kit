import AppKit

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
    static func isRunning(_ device: Device) -> Bool {
        !Mirror.pids(device, .keyboard).isEmpty
    }

    static func start(_ device: Device) {
        guard let link = Mirror.currentLink(device) else {
            Shell.log("keyboard-only aborted: \(device.id) not connected")
            return
        }
        Shell.log("starting \(device.id) keyboard-only session")
        // `--no-video --no-audio` together are what mark this out from the other
        // two session kinds; see Mirror.Session. Neither is incidental.
        Shell.launchDetached(Config.scrcpy, [
            "-s", link.serial,
            "--no-video",
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
        Mirror.terminate(Mirror.pids(device, .keyboard))
        Shell.log("\(device.id) keyboard-only session stopped")
    }
}
