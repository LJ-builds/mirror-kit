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
