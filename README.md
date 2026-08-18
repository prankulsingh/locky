# locky

A semi-transparent "don't touch my laptop" overlay for macOS. It covers every
screen, asks for a password, and keeps the Mac awake while it's up — so you can
step away from a machine running long jobs without someone sending a prank
Slack message from your seat.

**It is not a security tool.** It does not lock your Mac, encrypt anything, or
survive a determined person. There is a deliberate no-password escape hatch, it
needs no permissions and no `sudo`, and everything it does is undone the instant
the process dies. It's a *deterrent* — a locked-looking screen that makes a
passer-by move along.

By default it also gets out of your *view*: after 5 idle seconds the banner
fades to a small lock in each screen's corner, so you can still watch your work
run. Any key, click or mouse move brings it straight back.

---

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Set a password](#set-a-password)
- [Dismiss](#dismiss)
- [Options](#options)
- [Spotlight and a keyboard shortcut](#spotlight-and-a-keyboard-shortcut)
- [Idle mode](#idle-mode)
- [Keyboard hardening](#keyboard-hardening)
- [Forensics log](#forensics-log)
- [Keeping the Mac awake](#keeping-the-mac-awake)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Design notes](#design-notes)
- [License](#license)

---

## Requirements

- macOS with the **Xcode Command Line Tools** (for `clang`):

  ```sh
  xcode-select --install
  ```

- Nothing else. No Xcode, no Homebrew, no dependencies, no Accessibility or
  Screen Recording permission, no `sudo`, no code signing.

Developed and tested on **macOS 26.3.1, Apple Silicon**. The APIs it uses are
old and stable, so older macOS versions very likely work — but that is untested,
so treat it as unverified rather than supported.

## Install

```sh
git clone https://github.com/YOURNAME/locky.git
cd locky
./locky
```

The first run compiles `locky.m` into `.build/locky` (about a second). After
that the binary is cached and only rebuilt when the source changes. There is no
separate build step and no Makefile — the `locky` wrapper script handles it.

To call it from anywhere, either symlink it onto your `PATH` or alias it:

```sh
ln -s "$PWD/locky" /usr/local/bin/locky
# or, in ~/.zshrc:
alias locky="$PWD/locky"
```

For launching it from Spotlight or a global hotkey, see
[Spotlight and a keyboard shortcut](#spotlight-and-a-keyboard-shortcut).

## Set a password

locky reads its password from `~/pass.txt`, trimmed of surrounding whitespace,
and falls back to `8888` if the file is missing.

```sh
echo 'your-password' > ~/pass.txt
chmod 600 ~/pass.txt
```

**This is a plaintext file.** That is a deliberate choice for a tool whose whole
threat model is "a colleague walking past", not "someone with an account on your
Mac". Do not reuse a password that protects anything real. `-p/--password`
overrides the file, but note that anything on a command line is visible in `ps`
to every user on the machine.

## Dismiss

- **Type the password** — it unlocks the instant it matches. No Enter needed.
- **✕** beside the field wipes it on every screen. Enter on a wrong entry does
  the same.

**Esc and ⌘Q are both swallowed on purpose.** They're the first things anyone
pokes at, so they had to go nowhere. The overlay displays no hint about how to
get out, because advertising the way out is exactly what defeats the point.

**By default there is no escape hatch at all** — the password is the only way
out. If you want a no-password quit, opt into one:

```sh
locky --escape-key k     # ⌘K quits without the password
locky --escape-key j     # or any single character
```

Its value comes entirely from nobody around you knowing which key it is, so pick
your own and don't write it down where colleagues can read it. Note that every
⌘-combination goes into the [forensics log](#forensics-log), including this one,
so the log names your hatch once you've used it.

> **Know your password before you launch.** With no escape hatch and strict mode
> both on by default, `~/pass.txt` is your only way out short of `pkill locky`
> over SSH from another machine. Killing it restores everything instantly, so
> nothing ever gets *stuck* — but you would have to walk to another machine.

## Options

```
-a, --alpha <0.05-0.95>   overlay opacity (default 0.55 — lower = see more)
-m, --message <text>      main line (default "Locked")
-s, --subtitle <text>     second line
-p, --password <text>     override ~/pass.txt
    --banner              keep the banner up permanently, never fade to idle
    --idle-delay <sec>    idle seconds before the banner fades (default 5)
    --no-focus-grab       don't pull focus back when you switch apps
    --no-strict           allow ⌘⌥Esc force-quit + the power-button dialog
                          (both are blocked by default)
    --escape-key <c>      add a ⌘<c> escape hatch that quits without the
                          password (default: none at all)
    --no-log              don't write ~/Library/Logs/locky.log
    --debug               print screen/window geometry and kiosk state
-h, --help
```

Examples:

```sh
locky                                   # the usual: fades to a corner lock
locky --banner                          # permanent banner, never fades
locky -a 0.3                            # barely-there tint, see everything
locky -s "back in 10 — build running"   # custom second line
locky --escape-key k                    # add a ⌘K no-password quit
locky --no-strict --debug               # troubleshooting
```

## Spotlight and a keyboard shortcut

A shell script cannot be indexed by Spotlight or targeted by Shortcuts.app, so
locky ships with a thin `.app` bundle whose only job is to be something
LaunchServices will index. It sets a sane `PATH`, then hands straight off to the
same `./locky` wrapper.

### 1. Create the bundle

Run this **from inside your locky checkout**. It is self-contained — copy the
whole block:

```sh
REPO="$PWD"
APP="$HOME/Applications/Locky.app"
BUNDLE_ID="io.github.prankulsingh.locky"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>              <string>Locky</string>
	<key>CFBundleDisplayName</key>       <string>Locky</string>
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

cat > "$APP/Contents/MacOS/Locky" <<LAUNCHER
#!/bin/bash
# Thin launcher so Spotlight / Shortcuts / Finder can start locky. All the real
# work (build-on-demand, caffeinate lifecycle) lives in the repo wrapper.
# A GUI launch gets a minimal environment and no terminal, so: pin a PATH, and
# keep a log, since anything printed would otherwise vanish.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
LOCKY="$REPO/locky"
LOG="$REPO/.build/launch.log"
mkdir -p "\$(dirname "\$LOG")"
exec "\$LOCKY" "\$@" >>"\$LOG" 2>&1
LAUNCHER
chmod +x "$APP/Contents/MacOS/Locky"

cp "$REPO/Locky.icns" "$APP/Contents/Resources/Locky.icns"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
```

Now type "locky" into Spotlight and press return.

The bundle records the repo path at creation time, so **re-run this block if you
move the checkout.**

### 2. Add a global hotkey

Using Shortcuts.app, which ships with macOS — no third-party tools:

1. Open **Shortcuts** → **+** to create a new shortcut.
2. Search the actions list for **Open App**, drag it in, and pick **Locky**.
3. Name the shortcut `Locky`.
4. In the right-hand sidebar (ⓘ) choose **Add Keyboard Shortcut**, then press
   your combination.

Pick something nobody hits by accident — ⌃⌥⌘L works well. The shortcut is
global, so it fires from any app.

### Two modes, two hits

If you want both the fading and the permanent-banner mode a Spotlight hit away,
run the block again with `APP="$HOME/Applications/Locky Banner.app"`, a different
`BUNDLE_ID`, and `--banner` appended to the `exec` line.

### The icon

`Locky.icns` is committed to the repo and copied into the bundle. It's the 🔒
Apple Color Emoji glyph rendered at all ten required icon sizes; macOS draws the
rounded container around it automatically. To change it, drop a different
`.icns` in as `Locky.icns` and re-run the block — `CFBundleIconFile` just says
`Locky`.

## Idle mode

Two states, and **only the paint changes between them** — the windows never
move, never resize and never go away.

| | Awake | Idle |
|---|---|---|
| Backdrop + banner text | shown | faded out |
| Password field | shown, focused | invisible, **still focused** |
| 🔒 | large, centred | small, bottom-right of every screen |
| Mouse clicks | eaten | **still eaten** |
| Keystrokes | → password field | **→ password field** |

So an idle locky looks like nothing is running, but nothing behind it is
reachable either. You can walk up to an apparently-untouched Mac and just type
the password. Every screen fades in lockstep; waking is fast (0.12s) and going
idle is slow (0.45s) — leaving should be unobtrusive, arriving should feel like
it slammed up.

`--banner` pins the awake state permanently. `--idle-delay` tunes the 5s.

Detecting the wake needs **no Accessibility permission and no global event
monitor**: locky is the active app with a window over every screen, so keys and
mouse moves are already being delivered to it. The full-screen window *is* the
sensor. Mouse movement has a 6px threshold so cursor drift and desk knocks don't
summon the banner all afternoon.

Because the field stays focused while invisible, a prankster's key-mashing lands
in it. Three things deal with that: the field clears itself every time locky goes
idle, there's a **✕ button** beside it, and pressing Enter on a wrong entry
clears it too. Password matching stays an exact comparison — leftovers are yours
to see and wipe, not something the tool quietly works around.

## Keyboard hardening

Blocking mouse clicks is easy — the overlay eats them. The keyboard is harder:
while locky is frontmost your keystrokes land in the password field, so the only
real hole is *anything that makes another app frontmost*. locky closes that with
kiosk presentation options, which need no permissions and no `sudo`:

| Vector | Status |
|---|---|
| Mouse clicks | blocked — the overlay eats them |
| ⌘Tab app switch | blocked (`DisableProcessSwitching`) |
| ⌘H hide | blocked (`DisableHideApplication`) |
| ⌘Q quit | swallowed — there is no hatch unless `--escape-key` adds one |
| Esc | swallowed |
| Dock / menu bar | hidden |
| Clicking another app's window | blocked — nothing behind is reachable |
| Anything that does steal focus | snapped back via `NSWorkspaceDidActivateApplication` |
| **⌘⌥Esc force-quit dialog** | blocked (`DisableForceQuit`) — **this was the one real bypass found in practice** |
| ⌘⌥⇧Esc held 3s | tested, bounces off; blocked anyway |
| ⌃↑ Mission Control, ⌃←/→ Spaces, ⌘F3 | tested, bounce off |
| ⌃⌘Q lock screen | tested, bounces off |
| Power-button shutdown dialog | blocked (`DisableSessionTermination`) |
| ⌘Space Spotlight | not blockable — see below |
| Physical: lid, power cable, hard power-off | not defensible in software |

These options only hold while locky is the active app, and **the system restores
everything the instant the process dies — including a `SIGKILL`.** Verified:
after `pkill -KILL locky`, the Dock and menu bar come straight back. It cannot
wedge your Mac.

Strict mode is the **default**, because ⌘⌥Esc was the only thing that ever
actually defeated the overlay in practice: Force Quit, pick locky, gone. The
cost is that the OS-level escape hatches go with it. Combined with the default
of no `--escape-key`, that leaves **the password, or `pkill locky` over SSH from
another machine**, as your only ways out while locky is up. Worth knowing before you rely on it. `--no-strict` hands the
force-quit and power-button dialogs back.

### The Spotlight hole

⌘Space is handled by the window server before any application sees it, so no
unprivileged process can suppress it. locky cannot close this one.

In practice it has not been reachable on a machine running locky — ⌘Space just
beeps and nothing opens — but treat that as luck rather than a guarantee. If you
want it genuinely shut, cheapest first:

1. Turn the Spotlight shortcut off in System Settings → Keyboard → Keyboard
   Shortcuts → Spotlight. One checkbox, and you probably won't miss it.
2. Strict mode (the default) narrows what someone can do once Spotlight *is*
   open, since they can't force-quit locky to get a clear view.
3. A `CGEventTap` could swallow every keystroke system-wide — but that needs
   Accessibility permission, which this tool deliberately avoids.

The overlay stays on top of Spotlight regardless, so they'd be typing blind.

## Forensics log

locky appends to `~/Library/Logs/locky.log`: modifier keystrokes, which app took
focus, and how it exited.

```
19:23:08.159  mod   @
19:23:08.303  key   @ k
19:23:08.303  EXIT  escape hatch
19:23:08.314  EXIT  clean shutdown
```

Modifiers are written as `@` Command, `^` Control, `~` Option, `+` Shift.

It exists to answer one question: *how did somebody get past this?* The trick is
that **locky can only log what is delivered to it, and that gap is itself the
finding.** A shortcut handled by the window server — Spotlight, Mission Control,
force quit — never reaches locky's monitor, so a log showing modifiers going
down, **no key**, and then another app taking focus tells you the keystroke was
eaten above locky. Read it as:

| Log ends with | Means |
|---|---|
| `EXIT escape hatch` / `EXIT password` | the `--escape-key` hatch, or the password |
| `EXIT signal 15` | someone ran `kill` |
| `FOCUS lost to Terminal` | went out through Spotlight |
| modifiers, no key, then **nothing at all** | `SIGKILL` — force quit |

That last row is not a gap in the log: `SIGKILL` cannot be caught by any
process, so the silence *is* the signature. The log is line-buffered precisely
so the lines before a kill survive it.

One caveat worth knowing: because every ⌘-combination is logged, **using an
`--escape-key` hatch records it** — `key @ k` sits right above `EXIT escape hatch`. That
is exactly what makes the log useful, but it does mean anyone who can read the
log learns your hatch. `--no-log` if that matters more than the forensics.

**Plain unmodified keystrokes are never recorded.** The password is typed as
ordinary key events and has no business sitting in a plaintext log, so only
modifier combinations and named keys (Esc, arrows, function keys) go in.
`--no-log` turns the whole thing off.

## Keeping the Mac awake

locky holds a caffeinate assertion for as long as it's up, so idle sleep won't
suspend whatever you stepped away from.

`caffeinate.sh` ships with the repo — a small wrapper around the built-in
`/usr/bin/caffeinate` that runs in the background, tracks a pidfile, and adds
`on` / `off` / `status` verbs. The `locky` wrapper sources it from the checkout,
so there is nothing to install.

Its pidfile lives in `$TMPDIR`, which means locky shares state with any other
copy of the same script — if you already source it from your `~/.zshrc`, the two
will not double-caffeinate. It is also usable on its own:

```sh
source ./caffeinate.sh
caffeinate on 2h     # or: on, off, status, help
```

If a caffeinate session was already running before locky started, it is left
alone on exit — locky only turns off what it turned on. Should `caffeinate.sh`
be missing from the checkout, locky falls back to plain
`/usr/bin/caffeinate -dims`.

Note this prevents *idle sleep*. It does not stop a lid close or a manual sleep.

## How it works

Three files matter:

| File | Role |
|---|---|
| `locky.m` | the whole application — one Objective-C file, no headers |
| `locky` | bash wrapper: build-on-demand, caffeinate lifecycle, then `exec`s the binary |
| `caffeinate.sh` | keep-awake helper, sourced by the wrapper; usable standalone |
| `Locky.icns` | app icon, copied into the `.app` bundle |

`.build/` holds the compiled binary and `launch.log`, and is gitignored.

The build is one command, which the wrapper runs for you:

```sh
clang -fobjc-arc -O2 -framework Cocoa -framework QuartzCore -o .build/locky locky.m
```

At runtime locky creates one borderless `NSWindow` per screen at
`CGShieldingWindowLevel()`, sets kiosk presentation options, and installs local
event monitors for keys, clicks and mouse movement. Everything else — the fades,
the idle timer, the password field — hangs off that.

## Troubleshooting

**`clang: command not found`** — install the Command Line Tools:
`xcode-select --install`.

**A Spotlight launch does nothing.** GUI launches have no terminal, so the
bundle redirects output to `.build/launch.log` in your checkout. Look there
first. The usual cause is a moved checkout — the bundle hardcodes the repo path,
so re-run the bundle creation block.

**Locky doesn't appear in Spotlight.** Re-register it:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Locky.app
```

Then confirm it resolved. This is the check that matters, because it asks
LaunchServices — the database Spotlight and Shortcuts actually launch apps
through:

```sh
osascript -e 'POSIX path of (path to application "Locky")'
```

If you want to check the Spotlight *metadata* index as well, note that
`mdfind -name Locky.app` does not reliably match app bundles. Use:

```sh
mdfind "kMDItemFSName == 'Locky.app'"
```

**The overlay draws but doesn't take the keyboard.** Something is running the
binary as a *child* process. macOS grants the right to become the frontmost app
to the process LaunchServices launched, and a child does not inherit it — which
is why the wrapper ends in `exec`. Don't wrap it in another shell that waits.

**The icon is stale in Spotlight or Finder.** That's the icon cache:
`killall Dock`.

**Can't get out.** The password, or your `--escape-key` hatch if you launched
with one. Failing that, from another machine:
`ssh you@mac 'pkill locky'`. The Dock and menu bar return immediately when the
process dies.

**Check what's actually applied.** `locky --debug` prints per-screen geometry and
a line like `kiosk: requested 0x1ea active=1 readback 0x1ea APPLIED`. `0x1ea` is
strict mode; `0x12a` is `--no-strict`.

## Uninstall

```sh
rm -rf ~/Applications/Locky.app
rm -f ~/Library/Logs/locky.log
rm -f /usr/local/bin/locky          # if you symlinked it
rm -rf /path/to/your/locky-checkout
```

locky installs no launch agents, writes nothing to `/Library`, and changes no
system settings. `~/pass.txt` is yours to delete.

## Design notes

The non-obvious decisions, and the traps behind them:

- **Windows sit at `CGShieldingWindowLevel()`** and join all Spaces, so they
  float above fullscreen apps too. Background work is untouched — the overlay is
  just a window.

- **The app runs as `NSApplicationActivationPolicyRegular`, not `.accessory`.**
  This matters more than it looks: under `.accessory`, `setPresentationOptions:`
  accepts `DisableProcessSwitching` and reads it back correctly but **does not
  enforce it** — ⌘Tab still works. Only a menu-bar-owning app gets real kiosk
  behaviour. The Dock icon and menu bar that `.regular` brings are hidden by
  those same options, so there's no visible cost.

- **The fades animate the views, never `window.alphaValue`.** A window at alpha 0
  stops receiving mouse events, so animating the window would have silently
  un-blocked the mouse for the entire idle period — a failure that fails *open*
  and looks fine while doing it. For the same reason the window keeps a 1.5%
  black floor under the backdrop rather than becoming a truly empty pane.

- **The faded-out banner is never set `hidden`.** Hiding a view resigns its
  first-responder status, and keeping the password field focused while invisible
  is the one thing idle mode has to preserve.

- **The wrapper `exec`s the overlay** instead of running it as a child, because
  foreground-activation rights belong to the process LaunchServices launched and
  are not inherited. Launched from Spotlight the old way, the overlay drew
  correctly on every screen but never took the keyboard — everything typed went
  to whatever was frontmost before. Sharing the PID fixes it, and means a `kill`
  aimed at locky reaches the overlay rather than a shell blocked waiting on it.
  Caffeinate cleanup therefore runs from a watcher process rather than an `EXIT`
  trap, which also fixed a pre-existing bug where killing the wrapper left the
  overlay running.

- **Focus is re-taken ~0.4s after you switch apps**, so typing the password
  always lands somewhere useful. `--no-focus-grab` turns that off.

- **One window per screen**, sized to that screen's exact frame; plugging or
  unplugging a display rebuilds them automatically. `--debug` prints the geometry
  if a display ever looks wrong.

- **Objective-C rather than Swift.** No principled reason beyond
  `clang -framework Cocoa` needing nothing but the Command Line Tools — no
  package manifest, no toolchain setup, and a build fast enough to run on every
  launch.

## License

Not yet chosen — add one before publishing. MIT is the conventional fit for
something this size.
