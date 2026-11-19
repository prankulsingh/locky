# AGENTS.md

Guidance for an AI coding agent (Claude Code or similar) helping someone
**install and use locky** from this repo. Read this before touching anything.
The full human docs are in [README.md](README.md); this file is the short,
agent-specific version plus the traps that matter when *you* are driving.

---

## ⚠️ The one rule: never launch the overlay yourself

`locky` (and `Locky.app`) puts an opaque-ish shield over **every screen**, grabs
the keyboard, hides the Dock and menu bar, and blocks ⌘Tab / ⌘Q / Force Quit.
**The only ways out are typing the password or `pkill locky` from another
machine over SSH.**

If you run it to "test" it, you will lock your user out of their own session.
**Do not run `./locky`, `Locky.app`, or `./locky --debug` as a verification
step.** When it's time to see it work, tell the user to launch it themselves and
dismiss it with their password.

Safe things you *may* run: `./locky --help` (prints usage and exits — it never
shows the overlay), `./install.sh`, the build, and the LaunchServices checks
below.

---

## What locky is (30 seconds)

A macOS "don't touch my laptop" deterrent overlay. Not a security tool — no
`sudo`, no permissions, no code signing, and everything it changes is undone the
instant the process dies (even on `SIGKILL`). One Objective-C file built with
`clang`. See the README for the full threat model.

---

## Installing it for a user

Do the steps **you can do**, and clearly hand the user the steps **only they
can do** (GUI dialogs — you can't click them). The order:

### Step 0 — Prerequisite: Xcode Command Line Tools  *(user may need to act)*

Check first:

```sh
xcode-select -p >/dev/null 2>&1 && command -v clang >/dev/null 2>&1 && echo OK
```

- Prints `OK` → move on.
- Otherwise → **the user must run this and click "Install" in the GUI dialog,
  then wait for the download to finish** (you can't script a GUI, and it's a
  large download):

  ```sh
  xcode-select --install
  ```

  The Command Line Tools provide both `clang` (to build) and `git` (to clone).
  Nothing else is required.

### Step 1 — Run the installer  *(you do this)*

```sh
./install.sh
```

It builds the binary, creates `~/Applications/Locky.app`, and registers it with
LaunchServices so Spotlight/Shortcuts/Finder can launch it. Safe to re-run.
`./install.sh --banner` also installs a permanent-banner variant.

### Step 2 — Set a password  *(you do this, with the user's chosen password)*

Until this file exists, locky uses the built-in default `8888`.

```sh
echo 'their-password' > ~/pass.txt && chmod 600 ~/pass.txt
```

It's plaintext by design (threat model is "colleague walking past"). Tell the
user not to reuse a real password. Don't echo the password back in your replies.

### Step 3 — Global keyboard shortcut  *(ONLY the user can do this — GUI)*

There is **no way to assign a global hotkey from the command line** on macOS
without third-party tools or Accessibility permission (which locky avoids). Hand
the user these exact steps:

1. Open **Shortcuts.app** (ships with macOS) → **+** for a new shortcut.
2. Add the **Open App** action, pick **Locky**.
3. Name the shortcut **Locky**.
4. In the **ⓘ** sidebar → **Add Keyboard Shortcut**, press a combo like
   **⌃⌥⌘L** (something nobody hits by accident).

Spotlight (`⌘Space`, type "locky") already works after Step 1 with no setup —
offer that as the zero-effort option if they don't want a hotkey.

---

## What works out of the box vs. not

| After `./install.sh` | Works OOB? |
|---|---|
| `./locky` from the checkout | yes |
| Spotlight: type "locky", return | yes |
| Finder double-click (no Gatekeeper nag — built locally, not quarantined) | yes |
| A global keyboard shortcut | **no — Step 3, user does it in Shortcuts.app** |

---

## Division of labor

| You (the agent) can | Only the user can (GUI) |
|---|---|
| Run `./install.sh`, build, edit source | Click through `xcode-select --install` |
| Check LaunchServices registration | Assign the global hotkey in Shortcuts.app |
| Write `~/pass.txt` (with their password) | Actually launch & dismiss the overlay |
| Run `./locky --help` | Turn off the Spotlight shortcut (if hardening) |

---

## Safe verification (no overlay shown)

```sh
# Did the bundle register? Either of these confirms it:
mdfind "kMDItemFSName == 'Locky.app'"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | grep -i Locky.app

# Does it build and parse args?
./locky --help
```

To confirm the overlay itself works, **ask the user** to launch it and type
their password — don't do it for them.

---

## Project layout

| File | Role |
|---|---|
| `locky.m` | the whole app — one Objective-C file |
| `locky` | bash wrapper: build-on-demand + caffeinate lifecycle, then `exec`s the binary |
| `install.sh` | one-command setup: build + create/register `Locky.app` |
| `caffeinate.sh` | keep-awake helper, sourced by the wrapper |
| `Locky.icns` | app icon copied into the bundle |
| `README.md` | full human documentation |

Build command (the wrapper runs it for you; here for reference):

```sh
clang -fobjc-arc -O2 -framework Cocoa -framework QuartzCore \
      -framework CoreAudio -o .build/locky locky.m
```

---

## Gotchas

- **Moving the checkout breaks the app bundle and wrapper**, which record this
  folder's path. Re-run `./install.sh` after moving it.
- **The wrapper `exec`s the binary** (shares its PID) so macOS grants it
  frontmost-activation rights. Don't wrap `locky` in another shell that waits on
  it, or the overlay draws but never takes the keyboard.
- **A Spotlight launch that does nothing** usually means a moved checkout — check
  `.build/launch.log` in the repo, then re-run `./install.sh`.
- **No secrets in this repo.** The only "password" present is the documented
  `8888` fallback; `~/pass.txt` lives in the user's home dir and is never
  tracked. Keep it that way.
