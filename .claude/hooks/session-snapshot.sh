#!/usr/bin/env bash
#
# SessionStart: record what was already dirty before this session touched
# anything, and arm the pre-commit hook.
#
# WHY A BASELINE EXISTS AT ALL
# "Commit your work" and "do not commit work that is not yours" are the same
# sentence, and neither hook nor human can tell those apart from a `git status`
# alone. A file that was already modified when the session opened is somebody
# else's - a crashed earlier run, a half-finished experiment, a deliberately
# corrupted source file waiting to be restored. Without a mark in the sand at
# t=0 the only honest instruction the Stop hook could give is "commit
# everything", which is precisely the instruction that shipped a corrupted file
# to main under the owner's name.
#
# WHAT THE BASELINE DOES NOT COVER - say it here so nobody trusts it further
# than it goes. A subagent that crashes mid-edit DURING this session leaves a
# half-written file that happened AFTER t=0, so it classifies as this session's
# own work and the Stop hook will ask the parent to commit it. Session-start
# baselining separates pre-session foreign work only. Worktree isolation is
# what covers the intra-session case; this file is not a substitute for it.
#
# ARMING
# The load-bearing check is .githooks/pre-commit, and git only runs it when
# core.hooksPath points at .githooks - which scripts/install-hooks.sh sets and
# which nobody remembers to run in a fresh clone or a fresh container. So this
# hook sets it when it is unset and the hook file is present. It never
# overwrites an existing setting: a repo that deliberately points elsewhere
# keeps its choice.
#
# This hook must never fail a session. Every path out of it exits 0.
#
set -uo pipefail

PAYLOAD="$(cat 2>/dev/null || true)"

HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=/dev/null
. "$HOOK_DIR/_snapshot-common.sh" || exit 0

# cwd from the stdin payload, not ${CLAUDE_PROJECT_DIR}: that variable does not
# follow into a worktree and would snapshot the wrong tree there.
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
SESSION="$(field session_id)"
[ -n "$SESSION" ] || SESSION="unknown"

ROOT="$(hooks_repo_root "$CWD")" || ROOT=""
# Not a git repository - a perfectly normal place to open a session. Nothing to
# baseline, nothing to say.
[ -n "$ROOT" ] || exit 0

# ------------------------------------------------------------------- arming --
if [ -f "$ROOT/.githooks/pre-commit" ]; then
  # The exec bit is checked unconditionally, not only when arming. git skips a
  # non-executable hook SILENTLY - no warning, no non-zero status, the commit
  # just goes through ungated. `cp` onto an existing file leaves the
  # destination's mode alone, so a hook that lost the bit once stays broken
  # through every later sync; scripts/install-hooks.sh sets it explicitly for
  # the same reason.
  if [ ! -x "$ROOT/.githooks/pre-commit" ]; then
    chmod +x "$ROOT"/.githooks/* 2>/dev/null || true
  fi
  CURRENT_PATH="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"
  if [ -z "$CURRENT_PATH" ]; then
    if git -C "$ROOT" config core.hooksPath .githooks 2>/dev/null; then
      echo "session-snapshot: armed core.hooksPath=.githooks (pre-commit refuses foreign staged files)"
    fi
  fi
fi

# ----------------------------------------------------------------- baseline --
# An unwritable cache directory is a machine fact, not a defect in the change
# being made, so it never fails the session - the Stop hook degrades to
# reporting when it finds no baseline.
hooks_write_snapshot "$ROOT" "$SESSION" || true

exit 0
