// The welcome window: the way in for someone who has just installed this and
// has never seen it before.
//
// The rule the whole thing is written to: never ask a person for something the
// Mac can find out, and never report a state without saying what to do about
// it. Every step either detects its own answer or offers the one button that
// gets past it — there is no step that can only be satisfied by leaving.

import AppKit
import SwiftUI

// MARK: - State

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, tools, connect, identify, network, finish
    }

    /// How the Mac will reach the device once the cable is out.
    enum Route: String, CaseIterable, Identifiable {
        case wifi, tailscale, usb
        var id: String { rawValue }
    }

    @Published var step: Step = .welcome

    // Tools
    @Published var scrcpyFound = false
    @Published var adbFound = false
    @Published var installing: String?          // label of what is being installed
    @Published var installFailure: String?
    /// Located once. It was a computed property, which meant a disk check on
    /// every pass of the view body.
    let brewPath: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    var toolsReady: Bool { scrcpyFound && adbFound }

    // Cable
    @Published var cable: DeviceSetup.CableState = .nothingPlugged
    @Published var found: DeviceSetup.Found?
    /// Guards against the 1.5s poll stacking probes on top of each other. adb
    /// can block for seconds, and without this a slow one just means two more
    /// are already queued behind it.
    private var probing = false

    // Naming
    @Published var deviceID = ""
    @Published var deviceName = ""
    @Published var isTablet = false
    var idProblem: String? {
        DeviceSetup.idProblem(deviceID, taken: Device.all.map(\.id))
    }

    // Addresses
    @Published var route: Route = .wifi
    @Published var wifiAddress: String?
    @Published var tailscaleAddress: String?
    @Published var typedAddress = ""
    @Published var lookingUpAddresses = false
    @Published var saving = false
    @Published var saveFailure: String?
    /// nil when there was nothing to test (a USB-only device).
    @Published var wirelessVerified: Bool?

    /// The address that will be written. Empty means USB-only, which is a
    /// legitimate answer rather than a missing one.
    var chosenAddress: String {
        switch route {
        case .wifi:      return wifiAddress ?? ""
        case .tailscale: return tailscaleAddress ?? typedAddress.trimmingCharacters(in: .whitespaces)
        case .usb:       return ""
        }
    }

    var addressProblem: String? {
        switch route {
        case .usb:
            return nil
        case .wifi:
            return wifiAddress == nil
                ? "This device isn't on Wi-Fi yet. Turn Wi-Fi on and check again."
                : nil
        case .tailscale:
            if tailscaleAddress != nil { return nil }
            let typed = typedAddress.trimmingCharacters(in: .whitespaces)
            if typed.isEmpty { return "Enter the device's Tailscale address." }
            let octets = typed.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) else {
                return "A Tailscale address starts with 100 and looks like 100.64.0.9"
            }
            return nil
        }
    }

    // Finish
    @Published var startAtLogin = true
    @Published var commandInstalled = false

    // MARK: Polling

    private var timer: Timer?

    /// Watches whatever the current step is waiting for. A poll rather than a
    /// notification because adb has nothing to subscribe to — but strictly
    /// read-only, so it costs the device nothing and can run as long as the
    /// window is open.
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard installing == nil else { return }   // brew is already being talked to
        switch step {
        case .tools:
            Task.detached {
                let scrcpy = FileManager.default.isExecutableFile(atPath: Config.scrcpy)
                let adb = FileManager.default.isExecutableFile(atPath: Config.adb)
                await MainActor.run { [weak self] in
                    self?.scrcpyFound = scrcpy
                    self?.adbFound = adb
                }
            }
        case .connect:
            guard !probing else { return }
            probing = true
            let needDetails = found == nil
            Task.detached {
                let state = DeviceSetup.probe(details: needDetails)
                await MainActor.run { [weak self] in
                    self?.probing = false
                    self?.apply(state)
                }
            }
        default:
            break
        }
    }

    private func apply(_ state: DeviceSetup.CableState) {
        cable = state
        guard case .ready(let device) = state else { return }
        // Only fill the fields the first time, or typing gets overwritten by
        // the next poll a second and a half later.
        guard found == nil else { return }
        found = device
        deviceID = DeviceSetup.suggestedID(for: device, taken: Device.all.map(\.id))
        deviceName = device.label
        isTablet = device.model.lowercased().contains("tab")
    }

    // MARK: Actions

    func install(_ what: String, args: [String], label: String) {
        guard let brew = brewPath else { return }
        installing = label
        installFailure = nil
        Task.detached {
            let (status, out) = Shell.run(brew, args)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.installing = nil
                self.scrcpyFound = FileManager.default.isExecutableFile(atPath: Config.scrcpy)
                self.adbFound = FileManager.default.isExecutableFile(atPath: Config.adb)
                let arrived = what == "scrcpy" ? self.scrcpyFound : self.adbFound
                if status != 0 && !arrived {
                    // The tail is where brew puts the reason; the rest is progress.
                    let tail = out.split(separator: "\n").suffix(8).joined(separator: "\n")
                    self.installFailure = tail.isEmpty ? "brew exited with status \(status)." : tail
                }
            }
        }
    }

    func installScrcpy() {
        install("scrcpy", args: ["install", "scrcpy"], label: "Installing scrcpy…")
    }

    func installADB() {
        install("adb", args: ["install", "--cask", "android-platform-tools"],
                label: "Installing adb…")
    }

    /// Reads both of the device's addresses off the cable, so the next step can
    /// show them rather than ask for them.
    func lookUpAddresses() {
        guard let serial = found?.serial else { return }
        lookingUpAddresses = true
        Task.detached {
            let wifi = DeviceSetup.wifiAddress(serial)
            let tailscale = DeviceSetup.tailscaleAddress(serial)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.wifiAddress = wifi
                self.tailscaleAddress = tailscale
                // Default to whatever keeps working from the most places. A
                // device on a tailnet still answers when its owner leaves the
                // house; one with neither address is a cable-only device, and
                // saying so beats offering a choice it cannot satisfy.
                self.route = tailscale != nil ? .tailscale : (wifi != nil ? .wifi : .usb)
                self.lookingUpAddresses = false
            }
        }
    }

    /// Switches the device to wireless debugging, proves the address answers,
    /// writes the config, and moves to the last step.
    func finishSetup() {
        guard let found else { return }
        let id = deviceID, name = deviceName, tablet = isTablet, host = chosenAddress
        saveFailure = nil
        saving = true
        Task.detached {
            var verified: Bool?
            if !host.isEmpty {
                DeviceSetup.enableWirelessDebugging(found.serial)
                verified = DeviceSetup.verifyWireless(host: host)
            }
            let failure: String?
            do {
                try DeviceSetup.save(id: id, name: name, host: host,
                                     isTablet: tablet, found: found)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            let result = failure, checked = verified
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.saving = false
                self.saveFailure = result
                self.wirelessVerified = checked
                guard result == nil else { return }
                // Back on the main actor, where this list is read from.
                Device.reload()
                Prefs.registerDefaults()
                // The toggle defaults to on, and a default nobody touches still
                // has to be applied — this used to wait for an onChange that
                // never came, so "Start at login" was on and doing nothing.
                LoginItem.set(self.startAtLogin)
                self.go(.finish)
            }
        }
    }

    // MARK: Navigation

    /// The first step that still has something to say. A Homebrew install
    /// arrives with scrcpy already present, so the tools step is often skipped
    /// outright — a step whose answer is already yes only costs a click.
    func advance() {
        switch step {
        case .welcome:
            scrcpyFound = FileManager.default.isExecutableFile(atPath: Config.scrcpy)
            adbFound = FileManager.default.isExecutableFile(atPath: Config.adb)
            go(toolsReady ? .connect : .tools)
        case .tools:    go(.connect)
        case .connect:  go(.identify)
        case .identify: go(.network); lookUpAddresses()
        case .network, .finish: break      // the Finish button calls finishSetup
        }
    }

    func back() {
        switch step {
        case .welcome:  break
        case .tools:    go(.welcome)
        case .connect:  go(toolsReady ? .welcome : .tools)
        case .identify: go(.connect)
        case .network:  go(.identify)
        case .finish:   break        // already written; going back would re-add it
        }
    }

    func go(_ next: Step) {
        step = next
        refresh()
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private var model: OnboardingModel?
    /// Restored when the window closes: the app lives in the menu bar, and the
    /// Dock icon is only borrowed for as long as there is a window with it.
    private var previousPolicy: NSApplication.ActivationPolicy = .accessory

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel()
        self.model = model
        let view = OnboardingView(model: model) { [weak self] in self?.close() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Set Up Mirror kit"
        // The step dots say where you are and each step has its own headline, so
        // a title bar caption on top of both is a third label saying less.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        // An accessory app has no menu bar, and without an Edit menu the
        // standard shortcuts are bound to nothing — so ⌘V does nothing in the
        // one field where somebody may well want to paste an address.
        installMainMenu()
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.startWatching()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopWatching()
        model = nil
        window = nil
        NSApp.setActivationPolicy(previousPolicy)
    }

    /// The smallest menu that makes text fields behave: an app menu so the
    /// leftmost slot is not empty, and an Edit menu so cut/copy/paste and
    /// select-all have key equivalents bound to them.
    private func installMainMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Mirror kit",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mirror kit",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

// MARK: - Shell

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome:  WelcomeStep(model: model)
                case .tools:    ToolsStep(model: model)
                case .connect:  ConnectStep(model: model)
                case .identify: IdentifyStep(model: model)
                case .network:  NetworkStep(model: model)
                case .finish:   FinishStep(model: model, dismiss: dismiss)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Clears the traffic lights, which sit over the content now that the
            // title bar is transparent and full-size.
            .padding(.top, 30)
            .padding(.horizontal, 46)

            Divider()
            Footer(model: model, dismiss: dismiss)
        }
        .frame(width: 660, height: 560)
    }
}

/// Progress on the left, actions on the right, in a bar of its own. Buttons at
/// the trailing edge is what every macOS sheet and assistant does, and it also
/// stops the primary action drifting into the middle of empty space.
struct Footer: View {
    @ObservedObject var model: OnboardingModel
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StepDots(current: model.step)
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var actions: some View {
        switch model.step {
        case .welcome:
            Button("Get Started") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .tools:
            Button("Back") { model.back() }
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.toolsReady)
        case .connect:
            Button("Back") { model.back() }
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.cable.isReady)
        case .identify:
            Button("Back") { model.back() }
            Button("Continue") { model.advance() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.idProblem != nil || model.deviceName.isEmpty)
        case .network:
            Button("Back") { model.back() }.disabled(model.saving)
            Button(model.saving ? "Setting Up…" : "Set Up Device") { model.finishSetup() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.addressProblem != nil || model.lookingUpAddresses || model.saving)
        case .finish:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}

/// Six dots rather than six words.
///
/// This was a labelled stepper, and at this width the connector lines won the
/// layout and hyphenated the labels down to "Wel-come" and "De-vice". Every step
/// already carries its own headline, so the labels were saying it twice — dots
/// say the one thing the headline cannot, which is how much is left.
struct StepDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                let done = step.rawValue < current.rawValue
                let here = step == current
                Capsule()
                    .fill(here ? Color.accentColor
                               : (done ? Color.accentColor.opacity(0.45)
                                       : Color.secondary.opacity(0.25)))
                    .frame(width: here ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.22), value: current)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }
}

/// Every step is the same shape — an icon, a headline, a sentence, then its own
/// controls. Keeping that identical between steps is most of what makes a wizard
/// feel like one thing rather than six dialogs.
struct StepScaffold<Content: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    let blurb: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(tint.opacity(0.13))
                    .frame(width: 88, height: 88)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(tint)
            }

            Text(title)
                .font(.system(size: 21, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 8)

            content()
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Steps

struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "iphone.gen3",
            title: "Put your Android device on this Mac",
            blurb: "Its screen in a window you can click. Your keyboard and trackpad "
                 + "working on it like real hardware. Its sound through your speakers.") {
            Text("Takes about a minute, and needs a USB cable just this once.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ToolsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: model.toolsReady ? "checkmark.circle" : "shippingbox",
            tint: model.toolsReady ? .green : .accentColor,
            title: model.toolsReady ? "Both tools are here" : "Two tools are needed",
            blurb: model.toolsReady
                ? "Nothing to install — go on."
                : "scrcpy does the mirroring. adb is how a Mac talks to an Android device. "
                + "Mirror kit drives them both.") {
            VStack(spacing: 9) {
                ToolRow(name: "scrcpy", detail: "the mirroring itself",
                        found: model.scrcpyFound, busy: model.installing != nil,
                        canInstall: model.brewPath != nil, install: model.installScrcpy)
                ToolRow(name: "adb", detail: "talking to the device",
                        found: model.adbFound, busy: model.installing != nil,
                        canInstall: model.brewPath != nil, install: model.installADB)

                if let installing = model.installing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(installing).font(.callout)
                        Text("· this can take a minute")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                if model.brewPath == nil && !model.toolsReady {
                    VStack(spacing: 5) {
                        Text("Homebrew isn't installed, and it is how these two arrive.")
                            .font(.callout)
                        // Qualified: this project has its own `Link` type for an
                        // adb connection, and it shadows SwiftUI's here.
                        SwiftUI.Link("Get Homebrew at brew.sh",
                                     destination: URL(string: "https://brew.sh")!)
                            .font(.callout)
                        Text("Install it, then come back — this window is watching.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }

                if let failure = model.installFailure {
                    ScrollView {
                        Text(failure)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 72)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.12)))
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 400)
        }
    }
}

struct ToolRow: View {
    let name: String
    let detail: String
    let found: Bool
    let busy: Bool
    let canInstall: Bool
    let install: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: found ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(found ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.monospaced())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if found {
                Text("installed").font(.caption).foregroundStyle(.secondary)
            } else if canInstall {
                Button("Install", action: install).disabled(busy)
            } else {
                Text("missing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.09)))
    }
}

/// The step that earns the whole window. Each adb state gets its own screen,
/// because "nothing plugged in" and "plugged in, waiting for you to tap Allow"
/// need opposite things from the person reading it — and the old setup script
/// answered both with the instructions for the first.
struct ConnectStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepScaffold(symbol: symbol, tint: tint, title: title, blurb: blurb) {
            VStack(spacing: 14) {
                switch model.cable {
                case .ready(let device):
                    HStack(spacing: 11) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.label).fontWeight(.medium)
                            Text(device.serial)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.12)))

                case .waitingForAuthorization:
                    // Nothing on this Mac can dismiss that prompt, so the only
                    // useful thing this window can do is point at the phone.
                    CalloutBox(icon: "hand.tap.fill", tint: .orange, lines: [
                        "Tap **Allow** on the device.",
                        "Tick “Always allow from this computer” and it won't ask again.",
                    ])

                case .adbMissing:
                    CalloutBox(icon: "exclamationmark.triangle.fill", tint: .orange, lines: [
                        "adb has gone missing since the last step.",
                        "Go back and install it, then come straight here.",
                    ])

                case .nothingPlugged, .connecting:
                    CalloutBox(icon: "info.circle.fill", tint: .secondary, lines: [
                        "**First time with this device?** Turn on developer access:",
                        "Settings › About phone › tap **Build number** seven times",
                        "Settings › Developer options › **USB debugging** › on",
                    ])
                }

                if !model.cable.isReady {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Watching the cable…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 450)
        }
    }

    private var symbol: String {
        switch model.cable {
        case .ready:                   return "checkmark.circle"
        case .waitingForAuthorization: return "hand.tap"
        case .adbMissing:              return "exclamationmark.triangle"
        case .connecting:              return "cable.connector"
        case .nothingPlugged:          return "cable.connector.horizontal"
        }
    }

    private var tint: Color {
        switch model.cable {
        case .ready:                                return .green
        case .waitingForAuthorization, .adbMissing: return .orange
        default:                                    return .accentColor
        }
    }

    private var title: String {
        switch model.cable {
        case .ready:                   return "Found it"
        case .waitingForAuthorization: return "Look at your device"
        case .connecting:              return "Almost…"
        case .adbMissing:              return "adb is missing"
        case .nothingPlugged:          return "Plug your device in"
        }
    }

    private var blurb: String {
        switch model.cable {
        case .ready:
            return "That's the hard part done. The cable comes out in a moment."
        case .waitingForAuthorization:
            return "It's connected and talking — it just wants your permission first, "
                 + "and only you can give it. The prompt is on the device's own screen."
        case .connecting:
            return "Something is on the cable but it isn't ready yet. Give it a moment."
        case .adbMissing:
            return "It was there a moment ago and isn't now."
        case .nothingPlugged:
            return "Connect it to this Mac with a USB cable. This is the only time you'll need one."
        }
    }
}

struct CalloutBox: View {
    let icon: String
    let tint: Color
    let lines: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    // ** ** in these strings is markdown, which Text renders.
                    Text(.init(line))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.12)))
    }
}

struct IdentifyStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "tag",
            title: "Give it a name",
            blurb: "The short name is what you type after `mirror` in a terminal. "
                 + "The full name is what the menu bar shows.") {
            VStack(alignment: .leading, spacing: 13) {
                LabeledField(label: "Short name") {
                    TextField("phone", text: $model.deviceID)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Spacer().frame(width: 104)
                    Text(model.idProblem ?? "Then run it with:  mirror \(model.deviceID)")
                        .font(.caption)
                        .foregroundStyle(model.idProblem == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                LabeledField(label: "Full name") {
                    TextField("My Phone", text: $model.deviceName)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(label: "Kind") {
                    Picker("", selection: $model.isTablet) {
                        Text("Phone").tag(false)
                        Text("Tablet").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack {
                    Spacer().frame(width: 104)
                    Text("A tablet gets the landscape option and its own icon.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: 410)
        }
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .frame(width: 92, alignment: .trailing)
            content()
        }
    }
}

struct NetworkStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "antenna.radiowaves.left.and.right",
            title: "How should this Mac reach it?",
            blurb: model.lookingUpAddresses
                ? "Reading the addresses off the device…"
                : "Both of these came from the device itself — there is nothing to look up.") {
            VStack(alignment: .leading, spacing: 10) {
                if model.lookingUpAddresses {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    RouteChoice(
                        selected: model.route == .wifi,
                        enabled: model.wifiAddress != nil,
                        title: "On your home Wi-Fi",
                        detail: model.wifiAddress ?? "the device isn't on Wi-Fi",
                        note: "Simplest. Stops working when you leave the network.",
                        select: { model.route = .wifi })

                    RouteChoice(
                        selected: model.route == .tailscale,
                        enabled: true,
                        title: "From anywhere, over Tailscale",
                        detail: model.tailscaleAddress ?? "not detected on the device",
                        note: "A free private network between your own machines.",
                        select: { model.route = .tailscale })

                    if model.route == .tailscale && model.tailscaleAddress == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Install Tailscale on the device and sign in with the same "
                               + "account as this Mac, then Check Again — or type its address.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextField("100.64.0.9", text: $model.typedAddress)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.leading, 30).padding(.trailing, 4)
                    }

                    RouteChoice(
                        selected: model.route == .usb,
                        enabled: true,
                        title: "Only over the cable",
                        detail: "no address",
                        note: "Mirrors while plugged in. You can add an address later.",
                        select: { model.route = .usb })

                    HStack(spacing: 10) {
                        Button("Check Again") { model.lookUpAddresses() }
                        if let problem = model.addressProblem {
                            Text(problem).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)

                    if let failure = model.saveFailure {
                        Text("Couldn't save: \(failure)")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: 440)
        }
    }
}

struct RouteChoice: View {
    let selected: Bool
    let enabled: Bool
    let title: String
    let detail: String
    let note: String
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).fontWeight(.medium)
                        Text(detail)
                            .font(.callout.monospaced())
                            .foregroundStyle(enabled ? Color.secondary : Color.orange)
                    }
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FinishStep: View {
    @ObservedObject var model: OnboardingModel
    var dismiss: () -> Void

    var body: some View {
        StepScaffold(
            symbol: "checkmark.circle",
            tint: .green,
            title: "\(model.deviceName) is ready",
            blurb: blurb) {
            VStack(alignment: .leading, spacing: 12) {
                if model.wirelessVerified == false {
                    CalloutBox(icon: "exclamationmark.triangle.fill", tint: .orange, lines: [
                        "It didn't answer on that address just now.",
                        "Check **Developer options › Wireless debugging** is on, then try "
                        + "`mirror \(model.deviceID)` — it will ask for the port if it needs one.",
                    ])
                }

                Toggle("Open Mirror kit when I log in", isOn: $model.startAtLogin)
                    .onChange(of: model.startAtLogin) { on in LoginItem.set(on) }

                if !CommandLineTool.isOnPath && CommandLineTool.bundledScript != nil {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Install the `mirror` terminal command").font(.callout)
                            Text("optional — the menu bar does the same things")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if model.commandInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Button("Install") {
                                model.commandInstalled = CommandLineTool.install()
                            }
                        }
                    }
                    if model.commandInstalled && !CommandLineTool.destinationOnPath {
                        Text("Add to ~/.zshrc to use it:  export PATH=\"$HOME/bin:$PATH\"")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 430)
        }
    }

    private var blurb: String {
        switch model.wirelessVerified {
        case true?:
            return "Tested — it answers over the network, so you can unplug the cable now.\n"
                 + "Look for the phone icon in your menu bar."
        case false?:
            return "Saved, but it didn't answer over the network yet."
        default:
            return "Set up over the cable. Look for the phone icon in your menu bar."
        }
    }
}

extension DeviceSetup.CableState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
