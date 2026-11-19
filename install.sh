#!/usr/bin/env bash
# install.sh — one-command setup for locky.
#
# What it does:
#   1. Checks the one prerequisite (the Xcode Command Line Tools, for clang).
#   2. Builds the binary (also proving the source compiles).
#   3. Creates a Locky.app launcher in ~/Applications and registers it so
#      Spotlight, Shortcuts.app and Finder can all start locky.
#   4. Tells you how to set a password and add a global hotkey.
#
# It installs NO launch agents, writes nothing to /Library, and changes no
# system settings. Everything it makes lives in this checkout and in
# ~/Applications. Uninstall is covered in the README.
#
# Safe to re-run: it rebuilds the bundle from scratch each time. The bundle
# records the path of THIS checkout, so re-run install.sh if you ever move it.
#
# Usage:
#   ./install.sh            # install the fading Locky.app
#   ./install.sh --banner   # ALSO install "Locky Banner.app" (permanent banner)
#   ./install.sh --help

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

BANNER=0
for arg in "$@"; do
  case "$arg" in
    --banner) BANNER=1 ;;
    -h|--help)
      # Print the leading comment block (everything from line 2 up to the
      # first non-comment line), with the "# " prefix stripped.
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) echo "install.sh: unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---- 1. prerequisite -------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
  cat >&2 <<'MSG'
✗ Missing the Xcode Command Line Tools (needed for clang).

  Run this, click "Install" in the dialog that appears, wait for it to finish:

      xcode-select --install

  Then run ./install.sh again. Nothing else is required — no Xcode, no
  Homebrew, no sudo.
MSG
  exit 1
fi
echo "✓ Command Line Tools present ($(clang --version | head -1))"

# ---- 2. build --------------------------------------------------------------
# Reuse the wrapper's own build-on-demand path so this never drifts from it.
# --help builds the binary, prints usage (discarded) and exits cleanly.
echo "🔨 building locky…"
"$REPO/locky" --help >/dev/null
echo "✓ built $REPO/.build/locky"

# ---- 3. the .app launcher bundle(s) ----------------------------------------
# A shell script can't be indexed by Spotlight or targeted by Shortcuts.app, so
# locky ships behind a thin .app whose only job is to hand off to ./locky.
make_bundle() {
  local NAME="$1" APP="$2" BUNDLE_ID="$3" EXTRA="$4"

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>              <string>$NAME</string>
	<key>CFBundleDisplayName</key>       <string>$NAME</string>
	<key>CFBundleExecutable</key>        <string>Locky</string>
	<key>CFBundleIconFile</key>          <string>Locky</string>
	<key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
	<key>CFBundlePackageType</key>       <string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key>           <string>1</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

  printf 'APPL????' > "$APP/Contents/PkgInfo"

  # GUI launches get a minimal environment and no terminal, so the launcher
  # pins a PATH and keeps a log. $REPO and $EXTRA expand now; everything with a
  # backslash stays literal for runtime.
  cat > "$APP/Contents/MacOS/Locky" <<LAUNCHER
#!/bin/bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
LOCKY="$REPO/locky"
LOG="$REPO/.build/launch.log"
mkdir -p "\$(dirname "\$LOG")"
exec "\$LOCKY" $EXTRA "\$@" >>"\$LOG" 2>&1
LAUNCHER
  chmod +x "$APP/Contents/MacOS/Locky"

  cp "$REPO/Locky.icns" "$APP/Contents/Resources/Locky.icns"
  "$LSREGISTER" -f "$APP"
  echo "✓ installed $APP"
}

make_bundle "Locky" "$HOME/Applications/Locky.app" "io.github.prankulsingh.locky" ""

if [[ "$BANNER" == "1" ]]; then
  make_bundle "Locky Banner" "$HOME/Applications/Locky Banner.app" \
              "io.github.prankulsingh.locky.banner" "--banner"
fi

# ---- 4. password + next steps ----------------------------------------------
echo
if [[ ! -f "$HOME/pass.txt" ]]; then
  cat <<MSG
⚠  No ~/pass.txt yet, so locky will use its built-in default password: 8888.
   Set your own before you rely on it (plaintext — don't reuse a real password):

       echo 'your-password' > ~/pass.txt && chmod 600 ~/pass.txt

MSG
else
  echo "✓ Password file ~/pass.txt found."
  echo
fi

cat <<MSG
Done. Try it:

  • Type "locky" into Spotlight (⌘Space) and press return.
  • Or run it from this folder:  ./locky

Add a global hotkey (optional, uses Shortcuts.app that ships with macOS):

  1. Open Shortcuts → + (new shortcut).
  2. Add the "Open App" action and pick "Locky".
  3. Name the shortcut "Locky".
  4. In the ⓘ sidebar choose "Add Keyboard Shortcut" and press your combo
     (⌃⌥⌘L works well — pick something nobody hits by accident).

Know your password before you launch: by default the only ways out are the
password or "pkill locky" over SSH from another machine.
MSG
