#!/usr/bin/env bash
# Install the mirror kit on this Mac:  bash install.sh
#
#   - checks for scrcpy and adb, and says how to get them if missing
#   - puts the `mirror` command on your PATH
#   - builds and installs the menu bar app (compiled here, so macOS never
#     quarantines it and no Apple Developer account is involved)
#   - writes the LaunchAgent with THIS machine's paths, so it starts at login
#   - leaves an existing ~/.config/mirror/devices.json alone
#
# Re-run it any time; it is idempotent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${MIRROR_BIN_DIR:-$HOME/bin}"
CONFIG_DIR="$HOME/.config/mirror"
CONFIG="$CONFIG_DIR/devices.json"
APP_DIR="${MIRROR_APP_DIR:-/Applications}"
APP="$APP_DIR/Android Mirror.app"
LABEL="com.mirrorkit.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SWIFT_DIR="$HERE/menubar"

say() { printf '→ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }

# ---------- 1. dependencies ------------------------------------------------
missing=()
for tool in scrcpy adb; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  cat >&2 <<EOF
❌ Missing: ${missing[*]}

Install them with Homebrew (https://brew.sh):
  brew install scrcpy android-platform-tools

Then run this script again.
EOF
  exit 1
fi
say "Found scrcpy $(scrcpy --version 2>/dev/null | head -1 | awk '{print $2}') and adb"

# ---------- 2. the CLI -----------------------------------------------------
mkdir -p "$BIN_DIR"
install -m 755 "$HERE/mirror" "$BIN_DIR/mirror"
say "Installed: $BIN_DIR/mirror"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. Add this to ~/.zshrc:"
     printf '     export PATH="%s:$PATH"\n' "$BIN_DIR" >&2 ;;
esac

# ---------- 3. config ------------------------------------------------------
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG" ]; then
  say "Keeping your existing $CONFIG"
else
  # A fresh install has no devices. Rather than invent one, hand the user
  # straight to the wizard that can read the answers off a USB cable.
  printf '{\n  "devices": [],\n  "notify": { "enabled": false }\n}\n' > "$CONFIG"
  say "Created empty $CONFIG"
  NEEDS_DEVICE=1
fi

# ---------- 4. the menu bar app -------------------------------------------
# Compiled on this machine on purpose: a locally built binary carries no
# com.apple.quarantine flag, so Gatekeeper never blocks it and the whole
# Developer ID / notarization requirement simply does not apply.
if [ ! -d "$SWIFT_DIR" ] || [ -z "$(ls "$SWIFT_DIR"/*.swift 2>/dev/null)" ]; then
  warn "Menu bar source not found in $SWIFT_DIR — installing the CLI only."
elif ! command -v swiftc >/dev/null 2>&1; then
  warn "swiftc not found, so the menu bar app was skipped. The CLI works fine."
  warn "To get it: xcode-select --install"
elif [ "$(uname -m)" != "arm64" ]; then
  warn "The menu bar app builds for Apple Silicon only; skipping it on $(uname -m)."
else
  say "Building the menu bar app…"
  BUILD_TMP="$(mktemp -d)"
  trap 'rm -rf "$BUILD_TMP"' EXIT
  # Every file in menubar/ — they are one module, so order does not matter and
  # there are no headers to keep in step. Swift requires the top-level code to
  # live in a file called main.swift; the rest is named after what it holds.
  swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
    "$SWIFT_DIR"/*.swift -o "$BUILD_TMP/mirror-menubar"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BUILD_TMP/mirror-menubar" "$APP/Contents/MacOS/mirror-menubar"
  ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.iphone.icns"
  [ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

  cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Android Mirror</string>
	<key>CFBundleDisplayName</key><string>Android Mirror</string>
	<key>CFBundleIdentifier</key><string>$LABEL</string>
	<key>CFBundleVersion</key><string>4.0.0</string>
	<key>CFBundleShortVersionString</key><string>4.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleExecutable</key><string>mirror-menubar</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLISTEOF

  # Ad-hoc signature keeps macOS from re-prompting for permissions on every
  # rebuild. It is enough precisely because the binary was produced here.
  codesign --force --sign - "$APP" >/dev/null 2>&1 || warn "ad-hoc codesign failed"
  touch "$APP"
  say "Installed: $APP"

  # ---------- 5. start at login -------------------------------------------
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/mirror-menubar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/mirror-menubar.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mirror-menubar.log</string>
</dict></plist>
PLISTEOF
  say "Wrote LaunchAgent: $PLIST"

  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || \
    launchctl load "$PLIST" >/dev/null 2>&1 || \
    warn "Could not start the agent; open $APP by hand."
fi

# ---------- 6. what next ---------------------------------------------------
echo
if [ -n "${NEEDS_DEVICE:-}" ]; then
  cat <<EOF
✅ Installed. One step left — add your device:

  1. Plug it into this Mac with a USB cable
  2. On the device: Settings -> About phone -> tap "Build number" 7 times,
     then Settings -> Developer options -> USB debugging -> ON
  3. Run:  mirror add

After that you can unplug the cable and just run:  mirror <id>
EOF
else
  echo "✅ Installed. Your devices:"
  "$BIN_DIR/mirror" list || true
fi
