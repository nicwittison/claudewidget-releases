#!/usr/bin/env bash
#
# uninstall.sh — removes ClaudeWidget's four install artifacts: the app
# bundle, the SMAppService login item, the App Group container, and the
# statusline relay hook installed into ~/.claude/settings.json.
#
# Produces: a restored ~/.claude/settings.json (statusLine reverted to the
# pre-relay backup, backup file removed), an unregistered SMAppService login
# item, a removed App Group container + relay dropfile directory, and the
# app bundle moved to ~/.Trash/ (recoverable, not permanently deleted).
#
# Idempotent: every removal step tolerates an already-absent target and
# reports "nothing to remove" rather than failing. Safe to re-run any number
# of times.
#
# Fail-loud: the one step that can silently corrupt user data — the jq
# statusLine restore — treats any non-zero jq exit or invalid backup JSON as
# FATAL and aborts before writing anything. Every other step is best-effort
# cleanup and continues past a missing target.
#
# Modes:
#   (default)    Detects artifacts, asks a single y/N confirm, then removes.
#   --yes        Skips the confirm prompt (for scripted/CI use).
#   --dry-run    Detects and prints what would be removed; touches nothing.
#                Ends with the terminal token UNINSTALL_DRY_RUN_OK.
#
# A real completed run ends with the terminal token UNINSTALL_COMPLETE.
#
# Test seams (env vars, override the real target paths with fixture paths):
#   UNINSTALL_SETTINGS_PATH         default: $HOME/.claude/settings.json
#   UNINSTALL_BACKUP_PATH           default: $HOME/.claude/.claudewidget-statusline-backup.json
#   UNINSTALL_GROUP_CONTAINER_PATH  default: $HOME/Library/Group Containers/group.422SMN7U5U.claudewidget
#   UNINSTALL_APP_PATH              default: /Applications/ClaudeWidget.app
#   UNINSTALL_DROPFILE_DIR          default: $HOME/.claude/claudewidget
#
# Requires only Apple-shipped tooling (/usr/bin/jq, osascript, /bin
# utilities) — never Homebrew, python3, or any non-preinstalled dependency,
# so this works unmodified on a stranger's Mac.
#
set -euo pipefail

# Anchor to the repo root — matches this repo's scripts/ house style, even
# though every path this script touches below lives outside the repo tree.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
ASSUME_YES=false

if [ $# -gt 2 ]; then
  echo "ERROR: too many arguments (usage: scripts/uninstall.sh [--yes] [--dry-run])" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --yes)
      ASSUME_YES=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (usage: scripts/uninstall.sh [--yes] [--dry-run])" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Config (env-seam overridable — see header)
# ---------------------------------------------------------------------------
SETTINGS_PATH="${UNINSTALL_SETTINGS_PATH:-$HOME/.claude/settings.json}"
BACKUP_PATH="${UNINSTALL_BACKUP_PATH:-$HOME/.claude/.claudewidget-statusline-backup.json}"
GROUP_CONTAINER_PATH="${UNINSTALL_GROUP_CONTAINER_PATH:-$HOME/Library/Group Containers/group.422SMN7U5U.claudewidget}"
APP_PATH="${UNINSTALL_APP_PATH:-/Applications/ClaudeWidget.app}"
DROPFILE_DIR="${UNINSTALL_DROPFILE_DIR:-$HOME/.claude/claudewidget}"

# WR-02: Steps 6-7 below are destructive/irreversible-adjacent (container
# removal, app bundle move) and ran under plain `set -e` with no
# containment — a failure there aborted immediately with only that one
# command's raw stderr, after Steps 4/5 (statusLine restore, login-item
# unregister) had already applied irreversibly, and no summary told the
# operator what succeeded vs. failed. Mirrors (at a shell-script level)
# `UninstallService.swift`'s StepFailure collection: `if ! cmd; then ...`
# is exempt from `set -e`'s abort (a command's exit status tested in a
# conditional is never subject to errexit), so failures are recorded here
# and reported in a closing summary instead of the script silently dying.
FAILED_STEPS=()

echo "==> uninstall.sh starting (dry-run=$DRY_RUN, yes=$ASSUME_YES)"

# ---------------------------------------------------------------------------
# STEP 1 — DETECT
# ---------------------------------------------------------------------------
echo "==> [1/6] Detecting installed artifacts"
FOUND=()
[ -d "$APP_PATH" ] && FOUND+=("App bundle: $APP_PATH")
FOUND+=("SMAppService login item: status unknown from shell — will attempt unregister")
[ -d "$GROUP_CONTAINER_PATH" ] && FOUND+=("App Group container: $GROUP_CONTAINER_PATH")
[ -f "$BACKUP_PATH" ] && FOUND+=("Statusline relay hook (backup present): $BACKUP_PATH")
[ -d "$DROPFILE_DIR" ] && FOUND+=("Relay dropfile directory: $DROPFILE_DIR")

if [ "${#FOUND[@]}" -eq 0 ]; then
  echo "    No known ClaudeWidget artifacts detected."
else
  printf '    %s\n' "${FOUND[@]}"
fi

# ---------------------------------------------------------------------------
# STEP 2 — CONFIRM (skipped for --yes and --dry-run)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = false ] && [ "$ASSUME_YES" = false ]; then
  echo
  read -r -p "Proceed with removing the above? [y/N] " CONFIRM_REPLY
  case "$CONFIRM_REPLY" in
    y|Y|yes|YES)
      ;;
    *)
      echo "==> Aborted by operator — no changes made."
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# STEP 3 — QUIT ANY RUNNING INSTANCE (install-local.sh idiom)
# ---------------------------------------------------------------------------
echo "==> [2/6] Quitting any running instance"
if [ "$DRY_RUN" = true ]; then
  echo "    (dry-run) would quit ClaudeWidget if running"
else
  osascript -e 'tell application "ClaudeWidget" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x ClaudeWidget 2>/dev/null || true
  sleep 1
fi

# ---------------------------------------------------------------------------
# STEP 4 — RESTORE STATUSLINE (mirrors RelayInstaller.restore(), jq-based)
# ---------------------------------------------------------------------------
echo "==> [3/6] Restoring statusLine"
if [ "$DRY_RUN" = true ]; then
  if [ -f "$BACKUP_PATH" ] && [ -f "$SETTINGS_PATH" ]; then
    echo "    (dry-run) would restore $SETTINGS_PATH's statusLine from $BACKUP_PATH, then remove the backup"
  elif [ -f "$BACKUP_PATH" ]; then
    # WR-01: the backup DOES exist here — only settings.json is missing
    # (e.g. Claude Code was uninstalled/reset between install and
    # uninstall). Misattributing this to "no backup found" would confuse
    # anyone troubleshooting a leftover backup file this branch never
    # cleans up.
    echo "    (dry-run) Claude Code's settings.json not found at $SETTINGS_PATH — would leave relay backup at $BACKUP_PATH in place (idempotent: nothing to restore)"
  else
    echo "    (dry-run) no backup found at $BACKUP_PATH — nothing to restore (idempotent)"
  fi
else
  if [ -f "$BACKUP_PATH" ] && [ -f "$SETTINGS_PATH" ]; then
    if ! jq -e . "$BACKUP_PATH" >/dev/null 2>&1; then
      echo "FATAL: backup file $BACKUP_PATH does not parse as valid JSON — refusing to restore (would corrupt $SETTINGS_PATH)." >&2
      exit 1
    fi
    TMP_SETTINGS=$(mktemp)
    if ! jq --slurpfile backup "$BACKUP_PATH" '.statusLine = $backup[0]' "$SETTINGS_PATH" > "$TMP_SETTINGS"; then
      echo "FATAL: jq failed to splice $BACKUP_PATH's statusLine into $SETTINGS_PATH — aborting before any write." >&2
      rm -f "$TMP_SETTINGS"
      exit 1
    fi
    mv "$TMP_SETTINGS" "$SETTINGS_PATH"
    rm -f "$BACKUP_PATH"
    echo "    Restored original statusLine command in $SETTINGS_PATH; removed backup."
  elif [ -f "$BACKUP_PATH" ]; then
    # WR-01: same distinction as the dry-run branch above — the backup
    # exists, only settings.json is missing, so this is NOT "no backup
    # found". The backup file itself is intentionally left in place (this
    # script never guesses at restoring into a settings.json that isn't
    # there).
    echo "    Claude Code's settings.json not found at $SETTINGS_PATH — leaving relay backup at $BACKUP_PATH in place (idempotent: nothing to restore)."
  else
    echo "    No relay backup found at $BACKUP_PATH — statusLine left untouched (idempotent: nothing to restore)."
  fi
fi

# ---------------------------------------------------------------------------
# STEP 5 — UNREGISTER LOGIN ITEM (headless app binary, never `open -a` —
# `open -a` does not reliably deliver args to a fresh process)
# ---------------------------------------------------------------------------
echo "==> [4/6] Unregistering login item"
BINARY="$APP_PATH/Contents/MacOS/ClaudeWidget"
if [ "$DRY_RUN" = true ]; then
  if [ -x "$BINARY" ]; then
    echo "    (dry-run) would run \"$BINARY\" --uninstall-cleanup to unregister the login item"
  else
    echo "    (dry-run) app binary not found at $BINARY — would print manual-removal fallback"
  fi
else
  if [ -x "$BINARY" ]; then
    "$BINARY" --uninstall-cleanup || true
    echo "    Login item unregister requested via $BINARY --uninstall-cleanup"
  else
    echo "    App binary not found at $BINARY — cannot unregister automatically."
    echo "    If ClaudeWidget still appears in System Settings > General > Login Items & Extensions, remove it manually there."
  fi
fi

# ---------------------------------------------------------------------------
# STEP 6 — REMOVE APP GROUP CONTAINER + RELAY DROPFILE DIRECTORY
# ---------------------------------------------------------------------------
echo "==> [5/6] Removing App Group container and relay dropfile directory"
if [ "$DRY_RUN" = true ]; then
  if [ -d "$GROUP_CONTAINER_PATH" ]; then
    echo "    (dry-run) would remove $GROUP_CONTAINER_PATH"
  else
    echo "    (dry-run) $GROUP_CONTAINER_PATH not present — nothing to remove"
  fi
  if [ -d "$DROPFILE_DIR" ]; then
    echo "    (dry-run) would remove $DROPFILE_DIR"
  else
    echo "    (dry-run) $DROPFILE_DIR not present — nothing to remove"
  fi
else
  if [ -d "$GROUP_CONTAINER_PATH" ]; then
    if rm -rf "$GROUP_CONTAINER_PATH"; then
      echo "    Removed $GROUP_CONTAINER_PATH"
    else
      echo "    WARNING: failed to remove $GROUP_CONTAINER_PATH — continuing (see closing summary)." >&2
      FAILED_STEPS+=("remove the App Group container ($GROUP_CONTAINER_PATH)")
    fi
  else
    echo "    $GROUP_CONTAINER_PATH not present — nothing to remove (idempotent)"
  fi
  if [ -d "$DROPFILE_DIR" ]; then
    if rm -rf "$DROPFILE_DIR"; then
      echo "    Removed $DROPFILE_DIR"
    else
      echo "    WARNING: failed to remove $DROPFILE_DIR — continuing (see closing summary)." >&2
      FAILED_STEPS+=("remove the relay dropfile directory ($DROPFILE_DIR)")
    fi
  else
    echo "    $DROPFILE_DIR not present — nothing to remove (idempotent)"
  fi
fi

# ---------------------------------------------------------------------------
# STEP 7 — MOVE APP BUNDLE TO TRASH (recoverable — never rm -rf the bundle)
# ---------------------------------------------------------------------------
echo "==> [6/6] Moving app bundle to Trash"
if [ "$DRY_RUN" = true ]; then
  if [ -d "$APP_PATH" ]; then
    echo "    (dry-run) would move $APP_PATH to ~/.Trash/"
  else
    echo "    (dry-run) $APP_PATH not present — nothing to remove"
  fi
elif [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
  # WR-07: Step 6 (App Group container / relay dropfile removal, directly
  # above) already recorded a failure into FAILED_STEPS. Before this gate
  # existed, Step 7 ran unconditionally regardless of that failure — the
  # opposite of `UninstallService.performUninstall()`'s own
  # `guard failures.isEmpty else { return .failed(...) }` gate before its
  # recycle step, which this script's header comment claims to mirror.
  # Skip moving the app bundle so a failed earlier step never leaves the
  # install in a worse partway state than necessary; the operator can
  # re-run the script (idempotent) once the earlier failure is resolved.
  echo "    Skipped — an earlier step failed (see closing summary below). Re-run this script after resolving it to remove the app bundle." >&2
else
  if [ -d "$APP_PATH" ]; then
    mkdir -p "$HOME/.Trash"
    APP_BASENAME=$(basename "$APP_PATH")
    DEST="$HOME/.Trash/$APP_BASENAME"
    if [ -e "$DEST" ]; then
      DEST="$HOME/.Trash/${APP_BASENAME%.app}-$(date +%Y%m%d%H%M%S).app"
    fi
    if mv "$APP_PATH" "$DEST"; then
      echo "    Moved $APP_PATH to $DEST"
    else
      echo "    WARNING: failed to move $APP_PATH to $DEST — continuing (see closing summary)." >&2
      FAILED_STEPS+=("move the app bundle to Trash ($APP_PATH)")
    fi
  else
    echo "    $APP_PATH not present — nothing to remove (idempotent)"
  fi
fi

if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
  echo "==> Done with failures — some steps could not complete:" >&2
  printf '    - %s\n' "${FAILED_STEPS[@]}" >&2
  # IN-04: this used to cite an internal "Steps 1-4" numbering scheme that
  # didn't match the [N/6] banners actually printed above (statusLine
  # restore is [3/6], login-item unregister is [4/6]) — refer to the named
  # steps only, matching the labels an operator can see in this run's own
  # output.
  echo "    Detection, quitting the running instance, statusLine restore, and login-item unregister above already ran; re-run this script to retry what failed." >&2
  exit 1
fi

echo "==> Done."
if [ "$DRY_RUN" = true ]; then
  echo "UNINSTALL_DRY_RUN_OK"
else
  echo "UNINSTALL_COMPLETE"
fi
exit 0
