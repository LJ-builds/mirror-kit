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

# ---------- presentation ----------------------------------------------------
# Colour only when a terminal is actually attached, so piping this to a file or
# a CI log does not fill it with escape codes.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OK=$'\033[32m'
  C_WARN=$'\033[33m'; C_ACCENT=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_OK=""; C_WARN=""; C_ACCENT=""; C_OFF=""
fi

TOTAL_STEPS=4
STEP_N=0

rule() { printf '%s────────────────────────────────────────────────────────%s\n' "${C_DIM}" "${C_OFF}"; }

# "[2/4] Tools" — a person watching a long install wants to know how much of it
# is left, and which part is currently taking its time.
step() {
  STEP_N=$((STEP_N + 1))
  echo
  printf '%s[%d/%d]%s %s%s%s\n' \
    "${C_ACCENT}" "${STEP_N}" "${TOTAL_STEPS}" "${C_OFF}" "${C_BOLD}" "$1" "${C_OFF}"
  rule
}

bold() { printf '%s%s%s\n' "${C_BOLD}" "$*" "${C_OFF}"; }
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "${C_OK}" "${C_OFF}" "$*"; }
note() { printf '  %s%s%s\n' "${C_DIM}" "$*" "${C_OFF}"; }
hmm()  { printf '  %s!%s %s\n' "${C_WARN}" "${C_OFF}" "$*"; }

# The closing frame. Someone who has just watched a wall of install output needs
# one place that says what they now have and what to do with it.
summary() {
  echo
  rule
  printf '  %s%s%s\n' "${C_OK}${C_BOLD}" "$1" "${C_OFF}"
  rule
  note "  mirror        ~/bin/mirror"
  note "  menu bar app  /Applications/Android Mirror.app  (starts at login)"
  note "  your devices  ~/.config/mirror/devices.json"
  echo
}

# Runs a slow command with a spinner instead of dead silence. Its output is kept
# and only shown if it fails — a successful `brew install` scrolling hundreds of
# lines past is noise, but a failed one is the only thing worth reading.
run_quietly() {
  local label="$1"; shift
  local log; log="$(mktemp)"
  if [ ! -t 1 ]; then
    printf '  %s… ' "${label}"
    if "$@" >"${log}" 2>&1; then echo "done"; rm -f "${log}"; return 0; fi
    echo "failed"; cat "${log}" >&2; rm -f "${log}"; return 1
  fi
  "$@" >"${log}" 2>&1 &
  local pid=$! i=0
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 "${pid}" 2>/dev/null; do
    i=$(( (i + 1) % 10 ))
    printf '\r  %s%s%s %s' "${C_ACCENT}" "${frames:$i:1}" "${C_OFF}" "${label}"
    sleep 0.1
  done
  if wait "${pid}"; then
    printf '\r  %s✓%s %s\n' "${C_OK}" "${C_OFF}" "${label}"
    rm -f "${log}"
    return 0
  fi
  printf '\r  %s✗%s %s\n' "${C_WARN}" "${C_OFF}" "${label}"
  sed 's/^/    /' "${log}" >&2
  rm -f "${log}"
  return 1
}
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
step "Tools"

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
  ok "scrcpy and adb are already here"
else
  say "Missing: ${need[*]}"
  say "scrcpy does the mirroring; adb is how a Mac talks to an Android device."
  if yes_no "Install them with Homebrew now?" "Y"; then
    for pkg in "${need[@]}"; do
      case "${pkg}" in
        android-platform-tools)
          run_quietly "Installing ${pkg} (a minute or so)" \
            brew install --cask android-platform-tools ;;
        *)
          run_quietly "Installing ${pkg} (a minute or so)" brew install "${pkg}" ;;
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
step "How this Mac reaches your device"
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
  ok "This Mac is on Tailscale as ${ts_ip}"
  say "Make sure the Android device has Tailscale too, signed into the same"
  say "account — you will be asked for its 100.x address in a moment."
else
  say "Fine — same Wi-Fi it is. You can switch to Tailscale later by editing"
  say "the address in ~/.config/mirror/devices.json."
fi
echo

# ---------- 3. install ------------------------------------------------------
step "Installing"
# install.sh narrates its own steps; compiling is the slow one, so it goes
# behind the spinner rather than sitting silent for half a minute.
run_quietly "Building and installing (compiles the app locally)" \
  bash "${HERE}/install.sh"
echo

# ---------- 4. the device ---------------------------------------------------
# Left until last because it needs a cable and some tapping on the device, and
# there is no point asking for that if a step above was going to fail.
step "Your device"
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
      summary "Ready"
      say "Look for the phone icon in your menu bar — that is the app."
      say "Or from a terminal:  mirror <id>"
      say "The cable has done its job; unplug it."
      break
    fi
    echo
    # No second diagnosis here. `mirror add` has just printed the specific one —
    # nothing plugged in, or plugged in and waiting for "Allow USB debugging?" to
    # be tapped — and repeating generic advice on top of it used to tell people
    # to enable USB debugging they had already enabled.
    say "Nothing was added. The message above says what to fix."
    echo
    if ! yes_no "Try again?" "Y"; then
      summary "Installed — no device yet"
      say "Everything else is in place. When the device is ready:  mirror add"
      break
    fi
  done
else
  summary "Installed"
  say "When you are ready, plug the device in and run:  mirror add"
fi
echo
