#!/usr/bin/env bash
# setup.sh — the friendly way in.  bash setup.sh
#
# install.sh is the plumbing: idempotent, silent, safe to re-run from a script.
# This is the part that talks to a person — it installs what is missing, explains
# the one decision that actually matters (how the Mac reaches the device), and
# hands over to `mirror add` at the end.
#
# Nothing here happens without being asked first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say()  { printf '  %s\n' "$*"; }
ask()  { # ask "question" "default"  -> echoes the answer
  # Reads the terminal directly so prompts still work when this script's stdin
  # is a pipe — but falls back to stdin when there is no terminal at all, so a
  # scripted `printf 'a\nn\n' | bash setup.sh` does not die on /dev/tty.
  # The prompt goes to stderr, always: this function's stdout is captured by the
  # caller, so anything printed there ends up inside the answer instead of on
  # the screen — which silently turned every reply into the default.
  local reply=""
  printf '  %s [%s]: ' "$1" "$2" >&2
  if [ -t 0 ]; then
    read -r reply || true                 # typed in a terminal
  elif [ -r /dev/tty ]; then
    read -r reply </dev/tty || true       # `curl … | bash`: stdin is the script
  else
    read -r reply || true                 # answers piped in
  fi
  printf '%s' "${reply:-$2}"
}
yes_no() { # yes_no "question" "Y|N" -> returns 0 for yes
  local d="$2" reply
  reply="$(ask "$1 (y/n)" "$d")"
  case "${reply}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

echo
bold "Mirror kit"
say "Puts an Android screen on this Mac, with the keyboard, trackpad and sound."
say "This will ask before installing or changing anything."
echo

# ---------- 1. Homebrew and the two tools ----------------------------------
bold "1. Tools"

if ! command -v brew >/dev/null 2>&1; then
  say "Homebrew is not installed, and it is how scrcpy and adb get here."
  say "Install it from https://brew.sh, then run this again."
  exit 1
fi

need=()
command -v scrcpy >/dev/null 2>&1 || need+=("scrcpy")
command -v adb    >/dev/null 2>&1 || need+=("android-platform-tools")

# swiftc comes from the Xcode command line tools, and a Mac that has never been
# used for development does not have them. install.sh degrades to a CLI-only
# install with a warning, which on a first run reads as "the app failed" — so
# ask here, while there is still someone to ask.
if ! command -v swiftc >/dev/null 2>&1; then
  say "The Xcode command line tools are missing. They provide the Swift compiler,"
  say "which builds the menu bar app locally — that is why this app never trips"
  say "Gatekeeper. The 'mirror' command works without them; the menu bar icon does not."
  if yes_no "Install them now? (Apple's installer opens in a window)" "Y"; then
    xcode-select --install 2>/dev/null || true
    say "Finish Apple's installer, then run this script again."
    exit 0
  else
    say "Continuing without the menu bar app."
  fi
fi

if [ "${#need[@]}" -eq 0 ]; then
  say "scrcpy and adb are already here. ✓"
else
  say "Missing: ${need[*]}"
  say "scrcpy does the mirroring; adb is how a Mac talks to an Android device."
  if yes_no "Install them with Homebrew now?" "Y"; then
    for pkg in "${need[@]}"; do
      case "${pkg}" in
        android-platform-tools) brew install --cask android-platform-tools ;;
        *) brew install "${pkg}" ;;
      esac
    done
  else
    say "Nothing installed. Run: brew install ${need[*]}"
    exit 1
  fi
fi
echo

# ---------- 2. how the Mac will reach the device ---------------------------
# The only decision with consequences. Both work; they differ in where you can
# be standing when they do.
bold "2. How should this Mac reach your device?"
echo
say "a) Same Wi-Fi only — nothing else to install. Works while both are on your"
say "   home network. If you leave the house, the mirror stops."
echo
say "b) Tailscale — a free private network between your own machines. The Mac"
say "   and the device get fixed addresses that work from anywhere, so you can"
say "   mirror a phone at home while you are not. Needs installing on both."
echo

# MIRROR_SETUP_ROUTE lets this be exercised without a person at the keyboard.
route="${MIRROR_SETUP_ROUTE:-$(ask "Choose a or b" "a")}"
USE_TS=0
case "${route}" in
  [Bb]*) USE_TS=1 ;;
esac

if [ "${USE_TS}" = "1" ]; then
  TS_BIN=""
  for candidate in "$(command -v tailscale 2>/dev/null || true)" \
                   "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
    [ -n "${candidate}" ] && [ -x "${candidate}" ] && { TS_BIN="${candidate}"; break; }
  done

  if [ -z "${TS_BIN}" ]; then
    say "Tailscale is not installed on this Mac."
    say "Get it from https://tailscale.com/download (or the Mac App Store),"
    say "sign in, then install it on the Android device from the Play Store and"
    say "sign in with the same account."
    say "Run this script again once both are signed in."
    exit 1
  fi

  ts_ip="$("${TS_BIN}" ip -4 2>/dev/null | head -1 || true)"
  if [ -z "${ts_ip}" ]; then
    say "Tailscale is installed but not connected. Sign in, then run this again."
    exit 1
  fi
  say "This Mac is on Tailscale as ${ts_ip}. ✓"
  say "Make sure the Android device has Tailscale too, signed into the same"
  say "account — you will be asked for its 100.x address in a moment."
else
  say "Fine — same Wi-Fi it is. You can switch to Tailscale later by editing"
  say "the address in ~/.config/mirror/devices.json."
fi
echo

# ---------- 3. install ------------------------------------------------------
bold "3. Installing"
bash "${HERE}/install.sh"
echo

# ---------- 4. the device ---------------------------------------------------
# Left until last because it needs a cable and some tapping on the device, and
# there is no point asking for that if a step above was going to fail.
bold "4. Your device"
echo
say "The device is added over a USB cable once; after that it is wireless."
echo
say "On the device:"
say "  Settings -> About phone -> tap \"Build number\" seven times"
say "  Settings -> Developer options -> USB debugging -> ON"
say "Then plug it into this Mac and accept the prompt it shows."
echo

if yes_no "Ready to add it now?" "Y"; then
  # Retried in place rather than treated as a failure. Forgetting to switch USB
  # debugging on is the single likeliest thing to go wrong here, and it is
  # fixed in ten seconds on the device — ending the whole wizard over it, after
  # everything else already succeeded, reads as though the install broke.
  while :; do
    echo
    if "${HOME}/bin/mirror" add; then
      echo
      bold "Done."
      say "Start it from the menu bar icon, or run:  mirror <id>"
      say "Unplug the cable — it is not needed again."
      break
    fi
    echo
    say "The device was not added. Nine times out of ten that is USB debugging:"
    say "  Settings -> About phone -> tap \"Build number\" seven times"
    say "  Settings -> Developer options -> USB debugging -> ON"
    say "then plug the cable in and accept the prompt on the device."
    echo
    if ! yes_no "Try again?" "Y"; then
      echo
      bold "Installed, with no device yet."
      say "Everything else is in place. When the device is ready, run:  mirror add"
      break
    fi
  done
else
  echo
  bold "Installed."
  say "When you are ready, plug the device in and run:  mirror add"
fi
echo
