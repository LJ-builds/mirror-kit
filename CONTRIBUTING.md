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
| `setup.sh` | The wizard. Asks the questions; delegates the work to `install.sh`. |
| `install.sh` | The plumbing. Idempotent, no questions, safe from a script. |
| `devices.example.json` | Every configurable field, with what it is for. |

The menu bar app is `menubar/*.swift`, one file per responsibility:

| | |
|---|---|
| `Config.swift` | Where adb and scrcpy are, project URLs. |
| `Device.swift` | Reading `devices.json`, plus the per-device preferences. |
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

**Audio and video buffers must be the same number.** Buffering only the audio
does not make it robust, it makes it late.

**The device's media volume is the capture gain.** scrcpy's default audio source
forwards the mix after volume is applied, so a phone at a quarter volume hands
the Mac a quarter-strength signal to amplify. It is raised while streaming and
put back afterwards — and dropped to zero across a restart, because the moment
scrcpy's audio process dies the phone starts playing out loud again.

## Testing

There is no test suite; it is a program whose entire job is talking to a physical
phone. What exists instead is a habit: change one thing, run `mirror <id>`, watch
`~/Library/Logs/mirror-menubar.log`, and check the arguments that came out with
`ps aux | grep scrcpy`. Most bugs here have been visible in that one line.

It has only ever been tested on Samsung devices. If you have anything else,
saying what happened is a genuinely useful contribution — see the README's
"What it is tested on" for which parts are most likely to be wrong elsewhere.
