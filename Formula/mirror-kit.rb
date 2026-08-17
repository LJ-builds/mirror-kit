# Homebrew formula for mirror kit.
#
# A formula rather than a cask on purpose. A cask downloads a prebuilt app, and
# anything downloaded gets macOS's quarantine flag — which, for an app with no
# Developer ID behind it, means Gatekeeper refuses to open it and the user ends
# up in System Settings hunting for "Open Anyway". Building here on the user's
# own machine produces a binary that was never downloaded, so that whole problem
# does not exist and no Apple Developer account is involved anywhere.
#
# See CONTRIBUTING.md for how to cut a release and update the sha256 below.
class MirrorKit < Formula
  desc "Mirror an Android phone or tablet on your Mac, with keyboard, trackpad and sound"
  homepage "https://github.com/LJ-builds/mirror-kit"
  url "https://github.com/LJ-builds/mirror-kit/archive/refs/tags/v5.0.0.tar.gz"
  sha256 "e4511528076b557044a5521168a6a24409c52f4ad823ce299072336dd0ce9014"
  license "Apache-2.0"
  head "https://github.com/LJ-builds/mirror-kit.git", branch: "main"

  # scrcpy does the actual mirroring. adb is the other half and cannot be
  # declared here: Homebrew ships it only as a cask (android-platform-tools),
  # and a formula cannot depend on a cask. The app's setup window installs it in
  # one click instead, and says so if it is missing — which is a better place
  # for it than a caveat nobody reads.
  depends_on :macos
  depends_on "scrcpy"

  def install
    # The menu bar app is built for Apple Silicon only, matching install.sh. An
    # Intel Mac gets a working `mirror` command and no app, rather than a failed
    # install.
    build_app if Hardware::CPU.arm?

    # Last, and not first: Homebrew's `install` *moves* what it is given, so
    # doing this earlier deletes the script out from under the app bundle that
    # wants its own copy.
    bin.install "mirror"
  end

  def build_app
    app = "Android Mirror.app"
    system "swiftc", "-swift-version", "5", "-O",
           "-target", "arm64-apple-macos13.0",
           *Dir["menubar/*.swift"],
           "-o", "mirror-menubar"

    (buildpath/"#{app}/Contents/MacOS").mkpath
    (buildpath/"#{app}/Contents/Resources").mkpath
    cp "mirror-menubar", "#{app}/Contents/MacOS/mirror-menubar"
    # A copy of the CLI inside the bundle, so the app can offer to install it
    # even when it was not put on the PATH by Homebrew.
    cp "mirror", "#{app}/Contents/Resources/mirror"

    icon = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.iphone.icns"
    cp icon, "#{app}/Contents/Resources/AppIcon.icns" if File.exist?(icon)

    (buildpath/"#{app}/Contents/Info.plist").write <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleName</key><string>Android Mirror</string>
        <key>CFBundleDisplayName</key><string>Android Mirror</string>
        <key>CFBundleIdentifier</key><string>com.mirrorkit.menubar</string>
        <key>CFBundleVersion</key><string>#{version}</string>
        <key>CFBundleShortVersionString</key><string>#{version}</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleExecutable</key><string>mirror-menubar</string>
        <key>CFBundleIconFile</key><string>AppIcon</string>
        <key>LSMinimumSystemVersion</key><string>13.0</string>
        <key>LSUIElement</key><true/>
      </dict>
      </plist>
    PLIST

    # Ad-hoc signature so macOS stops re-prompting for permissions on every
    # upgrade. Enough precisely because the binary was produced here.
    quiet_system "codesign", "--force", "--sign", "-", "#{buildpath}/#{app}"

    prefix.install app
  end

  def caveats
    <<~EOS
      Open the app to set up your first device:
        open "#{opt_prefix}/Android Mirror.app"

      It will walk you through it and offer to start itself at login.

      adb has to come from a cask, so Homebrew cannot install it as a
      dependency here. The setup window offers to do it in one click, or:
        brew install --cask android-platform-tools
    EOS
  end

  test do
    # Exercises the CLI's argument handling without needing adb, scrcpy, or a
    # device — `help` returns before any tool is looked up.
    assert_match "mirror the physical screen", shell_output("#{bin}/mirror help")

    # An empty config is a supported state (a fresh install), and listing it
    # must say so rather than fail.
    (testpath/"devices.json").write('{"devices":[]}')
    output = shell_output("MIRROR_CONFIG=#{testpath}/devices.json #{bin}/mirror list")
    assert_match "No devices configured", output

    menubar = prefix/"Android Mirror.app/Contents/MacOS/mirror-menubar"
    assert_predicate menubar, :executable? if Hardware::CPU.arm?
  end
end
