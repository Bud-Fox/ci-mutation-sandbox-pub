#!/usr/bin/env bash
#
# Stop: refuse to end a turn that leaves THIS SESSION'S work uncommitted, and
# name the work that is not this session's so it does not get swept in.
#
# This replaces the blanket "commit and push everything at the end". That
# instruction is what put a deliberately corrupted source file on main: the
# tree was dirty for reasons the agent had nothing to do with, and "everything"
# included them. The set this hook asks for is
#
#     dirty now  MINUS  dirty at session start
#
# and everything in the intersection is reported as explicitly NOT to commit.
#
# LIMITS - this cannot be the only thing between a dirty tree and lost work:
#   * Claude Code overrides a Stop hook after 8 CONSECUTIVE blocks. An agent
#     that cannot commit (no identity configured, a pre-commit refusal it does
#     not understand) burns through those and then stops being asked at all.
#   * The hook does not fire on a user interrupt. Ctrl-C leaves the tree
#     exactly as dirty as it was and nothing here runs.
#   * A turn that ends in an API error routes to StopFailure, whose output is
#     ignored. The most likely moment to lose work is the one moment this hook
#     is guaranteed silent.
# .githooks/pre-commit is the durable check; this one is a reminder with teeth.
#
# WHAT COUNTS AS "NOT THIS SESSION'S" IS NARROWER THAN IT SOUNDS. Only work
# that predates session start. A subagent that crashed mid-edit DURING this
# session produced its half-file after t=0, so it lands in "yours" and this
# hook will ask the parent to commit it. See session-snapshot.sh.
#
set -uo pipefail

PAYLOAD="$(cat 2>/dev/null || true)"

HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=/dev/null
. "$HOOK_DIR/_snapshot-common.sh" || exit 0

field() {
  local key="$1" py
  for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1; then
      printf '%s' "$PAYLOAD" | "$py" -c 'import json,sys
try:
    print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception:
    print("")' "$key" 2>/dev/null
      return 0
    fi
  done
  printf ''
}

CWD="$(field cwd)"
[ -n "$CWD" ] || CWD="$PWD"

ROOT="$(hooks_repo_root "$CWD")" || ROOT=""
[ -n "$ROOT" ] || exit 0

WORK="$(mktemp -d 2>/dev/null)" || exit 0
trap 'rm -rf "$WORK"' EXIT

hooks_dirty_paths "$ROOT" >"$WORK/now" 2>/dev/null || : >"$WORK/now"

# A clean tree is the overwhelmingly common case and says nothing.
[ -s "$WORK/now" ] || exit 0

SNAP="$(hooks_snapshot_file "$ROOT")" || SNAP=""
SNAP_OK=0
STALE_NOTE=""
if [ -n "$SNAP" ] && [ -f "$SNAP" ]; then
  SNAP_ROOT="$(hooks_snapshot_meta "$SNAP" root || true)"
  if [ "$SNAP_ROOT" = "$ROOT" ]; then
    SNAP_OK=1
    hooks_snapshot_entries "$SNAP" | cut -d' ' -f2- | LC_ALL=C sort -u >"$WORK/base"
    SNAP_HEAD="$(hooks_snapshot_meta "$SNAP" head || true)"
    NOW_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo UNBORN)"
    if [ -n "$SNAP_HEAD" ] && [ "$SNAP_HEAD" != "$NOW_HEAD" ]; then
      # Commits landed, or the branch was switched, since the baseline was
      # taken. The path set is still the best evidence available, but a reader
      # deciding what to trust needs to know it was taken against another HEAD.
      STALE_NOTE="(baseline was taken at HEAD ${SNAP_HEAD:0:12}, now ${NOW_HEAD:0:12} - it still names what was dirty before this session)"
    fi
  fi
fi

if [ "$SNAP_OK" -eq 0 ]; then
  # No usable baseline. DEGRADE TO REPORTING, never to demanding: the only
  # commit this hook could ask for here is an unscoped one, and an unscoped
  # commit is the exact failure the whole hook set exists to prevent. Saying
  # "commit these" while admitting it cannot tell whose they are would be worse
  # than saying nothing.
  echo "stop-uncommitted: no session baseline for $ROOT."
  echo "This hook cannot tell your work from what was already here, so it is"
  echo "reporting only - do NOT commit these wholesale. Decide per path, and stage"
  echo "each one you actually changed by name. Dirty paths:"
  sed 's/^/  /' "$WORK/now"
  # Seed a baseline so the next session in this tree is not equally blind.
  # Everything dirty right now becomes "was already here", which is the
  # conservative reading: it can cause a file to be under-claimed, never
  # somebody else's work to be committed.
  if hooks_write_snapshot "$ROOT" "stop-hook-seed"; then
    echo "A baseline has been recorded now, so the next session can tell the difference."
  fi
  exit 0
fi

LC_ALL=C comm -23 "$WORK/now" "$WORK/base" >"$WORK/mine"
LC_ALL=C comm -12 "$WORK/now" "$WORK/base" >"$WORK/foreign"

# Nothing appeared after the baseline. Whatever is dirty was dirty on arrival,
# and saying so unprompted at the end of every turn is noise that gets the hook
# switched off. Silence.
[ -s "$WORK/mine" ] || exit 0

{
  echo "Uncommitted work from this session. Commit it before ending the turn."
  [ -n "$STALE_NOTE" ] && echo "$STALE_NOTE"
  echo
  echo "Changed after this session started - yours, commit these:"
  sed 's/^/  /' "$WORK/mine"
  echo
  if [ -s "$WORK/foreign" ]; then
    echo "Already dirty when this session started - NOT yours. Do NOT commit these,"
    echo "do not restore them, do not include them in any pathspec:"
    sed 's/^/  /' "$WORK/foreign"
    echo
  fi
  echo "Stage an explicit pathspec listing only the paths in the first group, e.g."
  echo "  git add <path> <path> && git commit -m '<what changed>'"
  echo "Do not use git add -A, -u, or . - and do not use git commit -a. Those would"
  echo "sweep in the second group, and .githooks/pre-commit will refuse the commit."
} >&2

exit 2
