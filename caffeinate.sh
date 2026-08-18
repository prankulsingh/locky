# ===========================================================================
#                       caffeinate — USER MANUAL
# ===========================================================================
#
# NAME
#     caffeinate — keep this Mac awake while unattended agents / long tasks run
#                  (convenience wrapper around the built-in /usr/bin/caffeinate)
#
# SYNOPSIS
#     caffeinate [on] [duration]
#     caffeinate off
#     caffeinate status
#     caffeinate help
#     caffeinate -<flags> [utility ...]      # passthrough to /usr/bin/caffeinate
#
# DESCRIPTION
#     Prevents the Mac from going to *idle sleep*, which is the only thing that
#     actually suspends your background tasks. Runs in the BACKGROUND so it does
#     not tie up your terminal, tracks its PID, and is safe to invoke twice
#     (it will not spawn duplicates).
#
#     This is a quality-of-life wrapper only — /usr/bin/caffeinate already does
#     the underlying work. The wrapper adds: background-by-default, on/off/status
#     verbs, human duration parsing, and duplicate-guarding.
#
# COMMANDS
#     on [duration]   Start keeping the Mac awake in the background.
#     (no args)       Same as `on` with no duration (indefinite).
#     off             Stop; normal power management / sleep resumes.
#     status          Show ACTIVE/INACTIVE, power source, and the live
#                     sleep-blocking assertions currently held.
#     help            Show the short built-in help.
#     -<flags> ...    Anything starting with '-' is passed straight to the real
#                     /usr/bin/caffeinate (e.g. `caffeinate -i make`).
#
# DURATION FORMAT
#     2h / 2H   -> hours          90m / 90M -> minutes
#     45s / 45S -> seconds        90        -> bare number = MINUTES
#     (omit entirely = stay awake indefinitely until `caffeinate off`)
#
# WHAT IT BLOCKS  (flags used internally: -dims)
#     -i  prevent SYSTEM IDLE sleep   <-- the important one; works on BATTERY,
#                                         and idle-sleep is what suspends tasks.
#     -d  prevent DISPLAY sleep
#     -m  prevent DISK idle sleep
#     -s  prevent SYSTEM sleep        <-- AC power ONLY (ignored on battery).
#
# EXAMPLES
#     caffeinate              # stay awake until you run 'caffeinate off'
#     caffeinate on 3h        # stay awake 3 hours, then auto-release
#     caffeinate on 90m       # stay awake 90 minutes
#     caffeinate status       # confirm assertions are actually held
#     caffeinate off          # let the Mac sleep normally again
#     caffeinate -i make      # keep awake only while `make` runs (passthrough)
#
# SCREENSAVER vs SLEEP  (important)
#     A screensaver does NOT suspend background processes — only SLEEP does.
#     caffeinate works via power-management assertions and does not talk to the
#     screensaver daemon, so the screensaver may still appear. That's harmless:
#     `-i` blocks the sleep, so your tasks keep running even behind a screensaver.
#
# MDM / MANAGED-LAPTOP NOTES
#     * On battery, rely on `-i` (system idle sleep). `-s` is AC-only.
#     * A hard MDM sleep policy can override assertions. Always verify with
#       `caffeinate status` that PreventUserIdleSystemSleep is actually held.
#     * Keeping the laptop on AC power gives the strongest guarantee.
#
# FILES
#     <locky-checkout>/caffeinate.sh              this script
#     $TMPDIR/keepawake.caffeinate.pid             PID of the active session
#
# SEE ALSO
#     man caffeinate  ·  pmset -g assertions  ·  pmset -g batt
# ===========================================================================
#
# <locky-checkout>/caffeinate.sh
# ---------------------------------------------------------------------------
# `caffeinate` — keep this Mac awake while unattended agents / long tasks run.
#
# macOS already ships /usr/bin/caffeinate. This function is a friendly wrapper
# around it that:
#   * runs in the BACKGROUND (doesn't tie up your terminal),
#   * has on / off / status subcommands,
#   * uses the flags that actually work on a battery-powered, MDM-managed Mac,
#   * and still passes through to the real caffeinate if you give it raw flags.
#
# WHY these flags (`-dims`):
#   -d  prevent the DISPLAY from sleeping
#   -i  prevent the SYSTEM from IDLE sleeping   <-- the important one; works on
#                                                   BATTERY too, and idle-sleep
#                                                   is what actually suspends
#                                                   your background tasks.
#   -m  prevent the DISK from idle sleeping
#   -s  prevent the SYSTEM from sleeping        <-- AC power ONLY (ignored on
#                                                   battery), harmless to keep.
#
# NOTE on the screensaver: caffeinate uses power-management *assertions* and
# does NOT talk to the screensaver daemon, so the screensaver may still kick
# in. That's fine — a screensaver does NOT suspend background processes; only
# actual SLEEP does. `-i` blocks the sleep, so your tasks keep running even if
# the screensaver is showing. (On a hard MDM sleep policy some assertions can
# be overridden; check `caffeinate status` / `pmset -g assertions` to confirm.)
# ---------------------------------------------------------------------------

_CAFFEINATE_PIDFILE="${TMPDIR:-/tmp}/keepawake.caffeinate.pid"

# Parse a human duration (2h / 90m / 45s / plain-number=minutes) into seconds.
_caffeinate_to_seconds() {
  local d="$1"
  case "$d" in
    *h|*H) echo $(( ${d%[hH]} * 3600 )) ;;
    *m|*M) echo $(( ${d%[mM]} * 60 )) ;;
    *s|*S) echo $(( ${d%[sS]} )) ;;
    ''|*[!0-9]*) return 1 ;;          # not a clean number -> invalid
    *) echo $(( d * 60 )) ;;          # bare number == minutes
  esac
}

_caffeinate_is_running() {
  [[ -f "$_CAFFEINATE_PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$_CAFFEINATE_PIDFILE" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

caffeinate() {
  local sub="$1"

  # Passthrough: raw flags (-i, -d ...) or a utility -> defer to real binary.
  if [[ "$sub" == -* ]]; then
    command caffeinate "$@"
    return $?
  fi

  case "$sub" in
    on|start|"")
      shift 2>/dev/null
      if _caffeinate_is_running; then
        echo "☕ Already keeping this Mac awake (pid $(cat "$_CAFFEINATE_PIDFILE")). Use 'caffeinate off' to stop."
        return 0
      fi

      local secs="" dur="$1"
      if [[ -n "$dur" ]]; then
        if ! secs="$(_caffeinate_to_seconds "$dur")"; then
          echo "❌ Bad duration '$dur'. Use e.g. 2h, 90m, 45s, or a bare number (minutes)."
          return 2
        fi
      fi

      # Launch the real binary by full path (NOT `command caffeinate`): under
      # nohup, `command` resolves to /usr/bin/command which forks caffeinate as
      # a child, so killing the tracked pid would orphan the real process and
      # leak its assertions. A direct exec means the tracked pid IS caffeinate.
      if [[ -n "$secs" ]]; then
        nohup /usr/bin/caffeinate -dims -t "$secs" >/dev/null 2>&1 &
      else
        nohup /usr/bin/caffeinate -dims >/dev/null 2>&1 &
      fi
      local pid=$!
      disown "$pid" 2>/dev/null
      echo "$pid" > "$_CAFFEINATE_PIDFILE"

      if [[ -n "$secs" ]]; then
        echo "☕ Keeping this Mac awake for ${dur} (pid $pid). Tasks won't be suspended by idle-sleep."
      else
        echo "☕ Keeping this Mac awake indefinitely (pid $pid). Run 'caffeinate off' when done."
      fi
      ;;

    off|stop|kill)
      if _caffeinate_is_running; then
        local pid
        pid="$(cat "$_CAFFEINATE_PIDFILE")"
        kill "$pid" 2>/dev/null
        rm -f "$_CAFFEINATE_PIDFILE"
        echo "😴 Stopped keeping awake (killed pid $pid). Normal power management resumes."
      else
        # Clean up any stray real caffeinate processes we may have missed.
        rm -f "$_CAFFEINATE_PIDFILE"
        echo "ℹ️  No keep-awake session was running."
      fi
      ;;

    status|st)
      if _caffeinate_is_running; then
        echo "☕ ACTIVE — keep-awake running (pid $(cat "$_CAFFEINATE_PIDFILE"))."
      else
        echo "😴 INACTIVE — this Mac will sleep per normal power settings."
      fi
      echo "--- power source ---"
      pmset -g batt 2>/dev/null | sed -n '2p'
      echo "--- active sleep-blocking assertions ---"
      pmset -g assertions 2>/dev/null | grep -E "PreventUserIdleSystemSleep|PreventUserIdleDisplaySleep|PreventSystemSleep" | grep -v "^ *0 " || echo "(none)"
      ;;

    help|-h|--help)
      cat <<'EOF'
caffeinate — keep this Mac awake (wrapper around /usr/bin/caffeinate)

  caffeinate [on] [duration]   start keeping awake in the background
                               duration: 2h | 90m | 45s | bare number = minutes
                               (no duration = indefinite)
  caffeinate off               stop / let the Mac sleep normally again
  caffeinate status            show whether it's active + live assertions
  caffeinate -<flags> ...      pass straight through to /usr/bin/caffeinate

Examples:
  caffeinate            # stay awake until you run 'caffeinate off'
  caffeinate on 3h      # stay awake for 3 hours, then auto-release
  caffeinate status
  caffeinate off
EOF
      ;;

    *)
      echo "❓ Unknown command '$sub'. Try: caffeinate help"
      return 2
      ;;
  esac
}
