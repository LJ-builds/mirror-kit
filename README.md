# Mirror kit

Put an Android phone or tablet on your Mac — the screen in a window you can
click, the keyboard and trackpad acting as real hardware on the device, and the
sound coming out of your Mac speakers. Like iPhone Mirroring, except it works
with Android, and over the internet if you want it to.

Two pieces, both optional on their own:

- **`mirror`** — the command line. `mirror phone`, `mirror phone sound`, etc.
- **Android Mirror.app** — a menu bar icon doing the same things with a mouse.

Both read the same device list, so adding a device once adds it everywhere.

The work is done by [scrcpy](https://github.com/Genymobile/scrcpy), which is where
the credit belongs. This wraps it: it remembers your devices, picks settings that
survive a jittery Wi-Fi link, gets past the lockscreen, and puts the whole thing
behind one command or one menu.

## What it is tested on

**A Galaxy Z Fold 8, a Galaxy S23 Ultra, and a Galaxy Tab S10 Ultra**, all Samsung,
all over [Tailscale](https://tailscale.com). That is the honest scope — the Fold is
what it was written for, and it is the device every rough edge was found on.

It should work on any device that speaks adb, because scrcpy does. But the parts
that had to be taught about a specific device live in `devices.json`, and defaults
that suit one phone are guesses elsewhere:

- **Screen-off** blanks capture on the Fold 8 (Android 17), so it is disabled for it
  via `screenOffBreaksCapture`. On your device it may work fine — try it.
- **Unlocking** is written against Samsung's lockscreen (`unlockStyle`). Other skins
  put the PIN prompt together differently; set `"unlockStyle": "none"` and unlock the
  device by hand if it misbehaves.
- **Samsung's accidental-switch-on guard** is detected by a window name only One UI
  has. Elsewhere the check simply never matches, which is harmless.
- **Folding** is handled by capturing display 0 and letting Android switch panels
  underneath. That is a foldable concern; on a normal phone it is one screen and
  nothing to think about.

If it does something stupid on a non-Samsung device, that is a bug worth reporting —
but be aware I cannot reproduce it, so please include what `mirror <id>` printed.

---

## Install

You need [Homebrew](https://brew.sh). Everything else is installed for you, after
being asked.

```bash
git clone https://github.com/LJ-builds/mirror-kit.git
cd mirror-kit
bash setup.sh
```

That walks through the whole thing: the tools, whether you want this to work on
your own Wi-Fi or from anywhere via Tailscale, and adding the device. Re-running
it is safe.

Already set up and just want the latest?  `git pull && bash install.sh` —
`install.sh` is the plumbing on its own, and it leaves your device list alone.

The menu bar app is compiled on your own machine, which is why there is no
"unidentified developer" warning to click past — and it is Apple Silicon only.
The `mirror` command works regardless.

Then add your device — plug it into the Mac with a USB cable first:

```bash
mirror add
```

That reads the device's own address off the cable, switches it to wireless
debugging, and writes it down. Unplug the cable and you are done:

```bash
mirror list          # what's configured
mirror <id>          # mirror it
```

If the device refuses to talk over USB, you need Developer options on it:
**Settings → About phone → tap "Build number" seven times**, then
**Settings → Developer options → USB debugging → ON**, and accept the prompt
that appears when you plug it in.

### About the menu bar app and Gatekeeper

`install.sh` compiles the app on your own machine rather than shipping you a
binary. That is deliberate: a locally built app carries no quarantine flag, so
macOS never blocks it and no Apple Developer account is involved anywhere. The
cost is that you need `swiftc`, which comes with the Xcode Command Line Tools
(`xcode-select --install`). Skip it and the `mirror` command still works alone.

---

## Using it

```
mirror <id>              mirror the screen; unlocks the device first if needed
mirror <id> sound        ...and bring its audio to the Mac
mirror <id> music        audio only — no window, device stays locked in a pocket
mirror <id> watch        mirror + sound, heavily buffered for watching video
mirror <id> keys         no mirroring; Mac keyboard/trackpad act as USB hardware
mirror <id> big          mirror a separate virtual screen, not the real one
mirror <id> hush         stop only the audio, keep the mirror running
```

They compose: `mirror phone watch speaker` is a buffered mirror with sound on
both ends. Anything else on the line is passed straight to `scrcpy`, so
`mirror phone -f` is fullscreen.

**`keys` is the interesting one.** It registers a genuine USB keyboard on the
device, so Android hands your keystrokes to the device's own input method —
which means Chinese, Japanese and Korean input work exactly as they do with a
Bluetooth keyboard. A small placeholder window appears and has to stay focused
for the Mac to forward what you type.

**`hush` exists because scrcpy has no runtime audio switch.** Audio always runs
as its own process, so stopping it hands the sound back to the device instantly
without dropping the mirror or the connection.

---

## Configuration

Everything lives in `~/.config/mirror/devices.json`. `mirror add` writes it;
after that it is a normal file you can edit. See `devices.example.json` for
every field with an explanation.

The fields worth knowing about:

| Field | What it does |
| --- | --- |
| `host` | LAN address, or a Tailscale one to reach the device from anywhere. Omit for a USB-only device |
| `kind` | `phone` or `tablet` — picks the icon and offers the tablet's force-landscape option |
| `unlockStyle` | `samsung` turns on One UI keyguard handling, `generic` does the basics, `none` never touches the lock screen |
| `virtualDisplay` | Size/dpi for `big`, e.g. `2448x1848/420`. Omit and the mode is refused rather than guessed |
| `screenOffBreaksCapture` | Set true if `--turn-screen-off` gives you a black mirror on this device |

### Mirroring from outside the house

Put [Tailscale](https://tailscale.com) on both the Mac and the device, then use
the device's Tailscale address (`100.x.y.z`) as its `host`. Nothing else
changes. On a LAN, a plain `192.168.x.x` address works and Tailscale is not
needed at all.

---

## Known limits

- **Apple Silicon only** for the menu bar app. The `mirror` command is fine
  anywhere.
- **The unlock automation was written against Samsung One UI.** On other makes
  it degrades to a wake-and-swipe (`unlockStyle: generic`) rather than typing a
  PIN. Set `unlockStyle: none` if you would rather it never tried.
- **An Android reboot turns wireless debugging off** and drops the pinned port.
  `mirror <id>` notices, explains it, and asks for the new port once; it then
  re-pins so the next launch needs nothing.
- **`--turn-screen-off` is broken on some devices** (verified on a Galaxy Z Fold
  8 running Android 17): the panel-off call kills the capture pipeline and the
  mirror goes permanently black. Use `big` instead — a virtual display works
  while the device is locked and shut.

---

## Optional: a "sound back to my phone" button

This one is for me, and it is left in because it costs nothing to ignore. I run a
small private HTTP service on the Mac and an [ntfy](https://ntfy.sh) topic on the
phone; filling in the `notify` block in `devices.json` makes starting audio push a
notification carrying a button that stops the stream. Those two services are not
part of this repo, so unless you happen to run something answering the same shape
of request, leave the block out. Nothing breaks without it — it is skipped
entirely, and `mirror <id> hush` still works from the Mac.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.mirrorkit.menubar
rm -rf "/Applications/Android Mirror.app" ~/Library/LaunchAgents/com.mirrorkit.menubar.plist
rm ~/bin/mirror
rm -rf ~/.config/mirror ~/.cache/mirror
```

## If it is useful to you

It is free and stays free. If it saved you an afternoon, you can
[buy me a coffee](https://github.com/sponsors/LJ-builds).

## License

Apache-2.0 — see [LICENSE](LICENSE). Same licence as scrcpy, which does the actual
work here; this only drives it, as a separate process, so nothing of scrcpy's or
FFmpeg's is linked into anything shipped from this repo.
