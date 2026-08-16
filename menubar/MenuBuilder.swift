// The menu, rebuilt from scratch every time it opens.
// Split out of MenuBarApp.swift so the state machine and the presentation
// can be read separately.

import AppKit

extension AppDelegate {
    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Pick up devices added by `mirror add` while this app was running.
        Device.reload()

        // Nothing configured yet — a fresh install. Offer the one thing that
        // helps instead of an empty menu with dead controls.
        if Device.all.isEmpty {
            let title = NSMenuItem(title: "No devices configured",
                                   action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for line in ["    1. Plug the device in over USB",
                         "    2. Enable USB debugging on it",
                         "    3. Run  mirror add  in Terminal"] {
                let hint = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
            menu.addItem(.separator())
            menu.addItem(item("Open Log", #selector(openLog), ""))
            menu.addItem(item("Quit", #selector(quit), "q"))
            return
        }

        if Config.toolsMissing {
            let warn = NSMenuItem(title: "scrcpy or adb not found — brew install scrcpy android-platform-tools",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let device = self.device
        let link = Mirror.currentLink(device)

        // Device picker. Each row carries its own state, so one device's status
        // is visible while another is selected.
        for candidate in Device.all {
            let candidateState = states[candidate.id] ?? .unreachable
            let mark = candidateState == .mirroring ? "  ● mirroring"
                     : candidateState == .unreachable ? "  — offline" : ""
            let row = item(candidate.menuName + mark, #selector(selectDevice(_:)), "")
            row.representedObject = candidate.id
            row.state = candidate.id == device.id ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())

        var headerText = busy ? busyLabel : state.label(for: device)
        if !busy, state != .unreachable, let link {
            headerText += link.isUSB ? " (USB)" : " (Wi-Fi)"
        }
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if busy {
            let wait = NSMenuItem(title: "Working…", action: nil, keyEquivalent: "")
            wait.isEnabled = false
            menu.addItem(wait)
        } else {
            switch state {
            case .mirroring:
                if lockedMidMirror.contains(device.id) {
                    // The mirror is up but showing a black rectangle, so this is
                    // the only useful thing to offer.
                    menu.addItem(item("Enter PIN to Unlock (mirror is blacked out)…",
                                      #selector(unlockNow), "u"))
                }
                menu.addItem(item("Stop Mirror", #selector(stopMirror), "s"))
            case .ready, .unreachable:
                menu.addItem(item("Start Mirror", #selector(startMirror), "m"))
                // Offered only where it works. On a phone whose capture dies with
                // the panel it is not a choice, and saying so in a dead menu row
                // spends a line telling the user what they cannot have.
                if !device.screenOffBreaksCapture && !Prefs.deviceCursor(device) {
                    menu.addItem(item("Start with Device Screen Off",
                                      #selector(startMirrorScreenOff), ""))
                }
            }

            // A separate session, not a mirror setting: useful precisely when you
            // are looking at the phone itself. Named so it cannot be confused
            // with the mirror's own keyboard option, which lives under Typing.
            let keysOn = keyboardOnly[device.id] ?? false
            let keys = item(keysOn ? "Stop Keyboard-Only Session"
                                   : "Keyboard Only — type with no mirror",
                            #selector(toggleKeyboardOnly), "k")
            keys.keyEquivalentModifierMask = [.command, .shift]
            keys.state = keysOn ? .on : .off
            menu.addItem(keys)

            menu.addItem(.separator())
            menu.addItem(item("Reconnect \(device.menuName)…", #selector(reconnectTablet), "r"))
        }

        menu.addItem(.separator())

        // Everything below is "how the mirror behaves" rather than "what to do
        // now", so it lives one level down. Two groups: what the picture costs,
        // and how input reaches the phone.
        menu.addItem(qualityMenuItem(device, link: link))
        menu.addItem(inputMenuItem(device))

        menu.addItem(.separator())
        menu.addItem(aboutMenuItem())
        menu.addItem(item("Open Log", #selector(openLog), ""))
        menu.addItem(item("Quit", #selector(quit), "q"))
    }

    /// "Picture & Sound": one axis of quality, plus the two things that change
    /// what the stream costs. The current pick is echoed in the parent title so
    /// the setting is readable without opening the submenu.
    func qualityMenuItem(_ device: Device, link: Link?) -> NSMenuItem {
        let sub = NSMenu()
        let usb = link?.isUSB ?? false

        let levelName: String
        if usb {
            levelName = "full quality (USB)"
            let note = NSMenuItem(title: "USB connected — 1920, H.265",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
            let why = NSMenuItem(title: "Bandwidth to spare, so nothing to trade off.",
                                 action: nil, keyEquivalent: "")
            why.isEnabled = false
            sub.addItem(why)
        } else {
            let frugal = Prefs.frugalVideo(device), sharp = Prefs.sharpVideo(device)
            levelName = sharp ? "Sharpest" : (frugal ? "Smoothest" : "Medium")

            let smoothest = item("Smoothest — 800, least data", #selector(selectFrugal), "")
            smoothest.state = (!sharp && frugal) ? .on : .off
            sub.addItem(smoothest)

            let medium = item("Medium — 1024", #selector(selectSmooth), "")
            medium.state = (!sharp && !frugal) ? .on : .off
            sub.addItem(medium)

            let sharpest = item("Sharpest — full resolution", #selector(selectSharp), "")
            sharpest.state = sharp ? .on : .off
            sub.addItem(sharpest)
        }

        sub.addItem(.separator())

        // Say what turning this on costs. Sound cannot be buffered without the
        // picture being buffered by the same amount — otherwise it simply plays
        // late — so enabling audio slows the video down to meet it. That is a
        // real change in how the mirror feels, and it should not be a surprise.
        let audio = item("Stream Device Audio  (adds ~0.12s, keeps it in sync)",
                         #selector(toggleAudio), "")
        audio.state = Prefs.streamAudio(device) ? .on : .off
        sub.addItem(audio)
        if Prefs.streamAudio(device) && !Prefs.watchMode(device) {
            let hint = NSMenuItem(
                title: "    picture is held back to match the sound",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
        }

        let watch = item("Watch Mode — buffered, adds ~0.5s lag",
                         #selector(toggleWatchMode), "")
        watch.state = Prefs.watchMode(device) ? .on : .off
        sub.addItem(watch)
        let watchHint = NSMenuItem(
            title: "    steadier video; leave off while clicking around",
            action: nil, keyEquivalent: "")
        watchHint.isEnabled = false
        sub.addItem(watchHint)

        let parent = NSMenuItem(title: "Picture & Sound  (\(levelName))",
                                action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// "Input": everything about how the Mac's keyboard and pointer reach the
    /// device while mirroring. The keyboard-only session is deliberately *not*
    /// here — it is an action, not a property of the mirror.
    func inputMenuItem(_ device: Device) -> NSMenuItem {
        let sub = NSMenu()

        // scrcpy fixes input modes at launch, so both of these relaunch the
        // mirror rather than switching it live.
        let kbd = item("Use Phone's Own Keyboard (IME)", #selector(toggleKeyboard), "k")
        kbd.state = Prefs.uhidKeyboard(device) ? .on : .off
        sub.addItem(kbd)
        let kbdHint = NSMenuItem(
            title: "    needed for Chinese; plain mode drops non-ASCII",
            action: nil, keyEquivalent: "")
        kbdHint.isEnabled = false
        sub.addItem(kbdHint)

        sub.addItem(.separator())

        let cursor = item("Show Cursor on Device", #selector(toggleCursor), "")
        cursor.state = Prefs.deviceCursor(device) ? .on : .off
        sub.addItem(cursor)
        let cursorHint = NSMenuItem(
            title: Prefs.deviceCursor(device)
                 ? "    press ⌘ or ⌥ to give the pointer back to the Mac"
                 : "    draws a pointer on the phone; adds a round trip of lag",
            action: nil, keyEquivalent: "")
        cursorHint.isEnabled = false
        sub.addItem(cursorHint)

        if device.supportsForceLandscape {
            sub.addItem(.separator())
            let land = item("Force Landscape on Tablet", #selector(toggleLandscape), "")
            land.state = Prefs.forceLandscape(device) ? .on : .off
            sub.addItem(land)
        }

        let parent = NSMenuItem(title: "Input & Typing", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// Kept behind one row on purpose. Reporting a bug is genuinely useful to
    /// someone mid-problem — this app is only tested on three Samsung devices,
    /// so other people's reports are the only way anything else gets fixed. But
    /// a menu is opened to get something done, and putting a donation link in
    /// the middle of that taxes every visit. One "About" holds both without
    /// either one standing in the way.
    func aboutMenuItem() -> NSMenuItem {
        let sub = NSMenu()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "?"
        let stamp = NSMenuItem(title: "Mirror kit \(version)", action: nil, keyEquivalent: "")
        stamp.isEnabled = false
        sub.addItem(stamp)

        let scrcpyNote = NSMenuItem(title: "Mirroring by scrcpy", action: nil, keyEquivalent: "")
        scrcpyNote.isEnabled = false
        sub.addItem(scrcpyNote)

        sub.addItem(.separator())

        let report = item("Report an Issue…", #selector(openIssues), "")
        sub.addItem(report)
        let project = item("Project Page", #selector(openProject), "")
        sub.addItem(project)

        sub.addItem(.separator())

        let sponsor = item("Buy Me a Coffee", #selector(openSponsor), "")
        sub.addItem(sponsor)

        let parent = NSMenuItem(title: "About Mirror kit", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openIssues()  { open(Config.issuesURL) }
    @objc func openProject() { open(Config.projectURL) }
    @objc func openSponsor() { open(Config.sponsorURL) }

    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
}
