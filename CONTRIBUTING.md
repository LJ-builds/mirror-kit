# Working on this

The whole thing is a wrapper around [scrcpy](https://github.com/Genymobile/scrcpy).
Nothing here decodes video or injects input — scrcpy does that. What lives here is
the part that remembers your devices, picks arguments that hold up on a jittery
link, gets past a lockscreen, and puts the result behind one command or one menu.

Read that sentence again before adding anything: if scrcpy can already do it with
a flag, the job here is choosing the flag well, not reimplementing it.

## Building

```bash
bash install.sh
```

Compiles the menu bar app and installs both pieces. Safe to re-run; it leaves
`~/.config/mirror/devices.json` alone. There is no project file and no package
manager — `swiftc menubar/*.swift` is the entire build.

## Where things are

| | |
|---|---|
| `mirror` | The CLI. One bash script, no dependencies beyond adb, scrcpy and python3 (used only to read the JSON config, so there is no `jq` requirement). |
| `Formula/mirror-kit.rb` | The Homebrew formula — the main way in. |
| `setup.sh` | The terminal wizard, for a clone. Asks the questions; delegates to `install.sh`. |
| `install.sh` | The plumbing. Idempotent, no questions, safe from a script. |
| `devices.example.json` | Every configurable field, with what it is for. |

The menu bar app is `menubar/*.swift`, one file per responsibility:

| | |
|---|---|
| `Config.swift` | Where adb and scrcpy are, project URLs. |
| `Device.swift` | Reading `devices.json`, plus the per-device preferences. |
| `DeviceSetup.swift` | Reading a device off a cable, and writing it into `devices.json`. |
| `Onboarding.swift` | The welcome window — the first thing anyone sees. |
| `LoginItem.swift` | Starting at login, and installing the `mirror` command. |
| `MirrorState.swift` | mirroring / ready / unreachable, and what each looks like. |
| `Shell.swift` | Running child processes and logging. |
| `Mirror.swift` | Starting and stopping mirrors; where scrcpy's arguments are decided. |
| `KeyboardOnly.swift` | The no-video session that attaches the Mac keyboard. |
| `Keyguard.swift` | Waking and unlocking the device. |
| `MenuBarApp.swift` | The app object and its state. |
| `MenuBuilder.swift` | Building the menu — presentation only. |
| `MenuActions.swift` | What each item does. |
| `main.swift` | Eight lines of entry point. Swift insists on the name. |

Both front doors read the same `devices.json`, so a device added in one appears
in the other. Keep it that way: anything device-specific belongs in that file
rather than in either program.

## Things worth knowing before you change them

**Never `kill -9` scrcpy.** If it dies mid-gesture it never sends the matching
touch-up, and Android leaves that pointer down forever — after which every
injected touch is rejected and the mirror looks alive but ignores the trackpad.
Plain SIGTERM everywhere.

**Nothing may poke the device on a timer.** Detection has to be read-only
(`dumpsys deviceidle` and friends). An earlier version retried the unlock every
few seconds while locked, which re-raised the PIN prompt forever, kept the phone
awake, and poisoned the pointer stream by interleaving injections with scrcpy's
own. Unlocking happens once, when a person asks for it.

**A serial without a colon is not a USB cable.** Wireless debugging advertises
itself over mDNS as `adb-XXXX._adb-tls-connect._tcp`. Match on the `usb:` field
in `adb devices -l` instead.

**Running sessions are told apart by flags, not by a marker.** There are three
kinds — mirror, sound, keyboard — and `Mirror.Session` sorts them by what they
were asked to do: video is what a mirror has and the other two do not, and of the
two videoless ones the keyboard is the one that also passes `--no-audio`. An
earlier version keyed the mirror to `--stay-awake`, which meant the first mode
with a reason not to pass that flag (the separate virtual screen, which must let
the device's own panel sleep) was invisible to `isMirroring` and unstoppable by
`stop`. Do not reintroduce a positive marker every new mode has to remember.

**Audio and video buffers must be the same number.** Buffering only the audio
does not make it robust, it makes it late.

**Sound is its own scrcpy process, in both front doors.** That is what makes it
detachable: killing it releases Android's playback capture without touching the
video stream or the adb connection, which is `mirror <id> hush` and the menu's
"Hand Sound Back". It also means a relaunch for a quality change does not
interrupt the sound at all — so only a change to the shared buffer needs the
device silenced across the gap.

**Both front doors pick the same numbers.** The three quality levels — 800/4M,
1024/6M, full/24M on Wi-Fi, and 1920/H.265/16M on USB — live in `Mirror.swift`
and in the `mirror` script's `SIZE_ARGS`/`CODEC_ARGS`. Change one and change the
other, or the same device starts looking different depending on how it was
started. The same goes for anything read out of `devices.json`: `unlockStyle`
was honoured by the CLI and quietly ignored by the app for a while, which meant
a device asking to be left alone still got woken and asked for a PIN.

**The device's media volume is the capture gain.** scrcpy's default audio source
forwards the mix after volume is applied, so a phone at a quarter volume hands
the Mac a quarter-strength signal to amplify. It is raised while streaming and
put back afterwards — and dropped to zero across a restart, because the moment
scrcpy's audio process dies the phone starts playing out loud again.

**Setup states are parsed, not assumed.** `DeviceSetup.parse` turns `adb devices
-l` output into one of five states, and the two that matter most are the ones an
earlier version ran together: "nothing plugged in" and "plugged in, waiting for
you to tap Allow". Those need opposite things from the reader, and answering the
second with instructions for the first is what made people re-enable USB
debugging they had already enabled. It is a pure function on purpose — it is the
part most likely to be wrong on hardware nobody here owns, so it is the part that
can be checked without any.

Two things it must keep getting right, both of which have bitten:

- `Shell.run` merges stderr into stdout, so adb's "* daemon not running; starting
  now at tcp:5037" arrives in the same string. Its first word looks like a serial.
  That is why device lines are matched on the *state* word, not by skipping known
  headers.
- A serial with no colon is not necessarily a cable, and a cable does not always
  carry a `usb:` field — adb omits it until the device is authorised, which is
  exactly the case this has to detect.

## Releasing

The formula builds from a release tarball, so cutting a release is: tag it, then
update `url` and `sha256` in `Formula/mirror-kit.rb`.

```bash
git tag v1.0.1 && git push --tags
curl -sL https://github.com/LJ-builds/mirror-kit/archive/refs/tags/v1.0.1.tar.gz | shasum -a 256
```

The formula lives in the tap repo (`LJ-builds/homebrew-tap`, as
`Formula/mirror-kit.rb`); the copy here is the source of truth to copy across.
Check it with `brew style Formula/mirror-kit.rb` before pushing, and test the
whole thing from a local tarball rather than waiting on a release:

```bash
brew install --build-from-source ./Formula/mirror-kit.rb
brew test mirror-kit
```

**A formula, not a cask, and that is not an arbitrary choice.** A cask downloads
a prebuilt app, and anything downloaded is quarantined; with no Developer ID
behind this app, Gatekeeper then refuses to open it and the user ends up in
System Settings hunting for "Open Anyway". Building on the user's own machine
sidesteps that completely. If you ever switch to shipping a binary, you are
signing up for an Apple Developer account and notarisation in the same move —
there is no half-way.

**A double-clickable installer .app has been tried, and it does not work.** The
tempting shortcut is to ship a small app that runs `setup.sh`, so nobody has to
open a terminal. Measured with `spctl -a -vv` on a bundle carrying a download's
quarantine attribute:

| | verdict |
|---|---|
| unsigned, no quarantine (built locally) | `rejected — no usable signature` |
| unsigned, quarantined (downloaded) | `rejected` |
| **ad-hoc signed, quarantined** | **`rejected`** |

The third row is the one that matters. Ad-hoc signing is what lets the menu bar
app avoid Gatekeeper today, and it does nothing here — that app is fine because
it is compiled on the user's machine and never downloaded, not because the
signature carries weight. Anything downloaded needs a real Developer ID and
notarisation, and there is no way around it worth finding.

**Homebrew's `install` moves what you give it.** `bin.install "mirror"` therefore
has to come *after* the app bundle takes its own copy of that script, or the
build fails on a missing file. It is the last line of `install` for that reason.

## Testing

There is no test suite; it is a program whose entire job is talking to a physical
phone. What exists instead is a habit: change one thing, run `mirror <id>`, watch
`~/Library/Logs/mirror-menubar.log`, and check the arguments that came out with
`ps aux | grep scrcpy`. Most bugs here have been visible in that one line.

It has only ever been tested on Samsung devices. If you have anything else,
saying what happened is a genuinely useful contribution — see the README's
"What it is tested on" for which parts are most likely to be wrong elsewhere.
