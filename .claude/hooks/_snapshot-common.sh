#!/usr/bin/env bash
#
# Shared helpers for session-snapshot.sh and stop-uncommitted.sh.
#
# NOT A HOOK. The leading underscore marks it as a library; nothing in
# settings.json points at it. It exists for exactly one reason: the two hooks
# have to agree, byte for byte, on where the snapshot file lives. Two copies of
# that path derivation drift the moment one is edited, and the failure is
# silent and one-directional - stop-uncommitted.sh looks for a snapshot that
# session-snapshot.sh wrote somewhere else, finds nothing, and degrades to
# "report only" forever. A gate that quietly stops gating is worse than no
# gate, so the derivation lives in one file.
#
# Sourced, never executed. Callers set their own `set` flags.

# The repository working tree containing $1, or empty if $1 is not in one.
# Written for a worktree: `git rev-parse --show-toplevel` returns the worktree
# path, which is what both hooks want. ${CLAUDE_PROJECT_DIR} does NOT follow
# into a worktree - it stays where the session started - so it is deliberately
# not used here. The hooks pass the `cwd` field from the hook's stdin JSON.
hooks_repo_root() {
  local start="${1:-}"
  [ -n "$start" ] || return 1
  [ -d "$start" ] || return 1
  git -C "$start" rev-parse --show-toplevel 2>/dev/null
}

# Directory the snapshots live in. Deliberately OUTSIDE the repository: a
# snapshot inside the tree would itself show up as an untracked file, which the
# stop hook would then report as this session's uncommitted work, and sooner or
# later someone stages it. It must never be committable.
hooks_snapshot_dir() {
  local base
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    base="$XDG_CACHE_HOME"
  elif [ -n "${HOME:-}" ] && [ -w "${HOME:-}" ]; then
    base="$HOME/.cache"
  else
    base="${TMPDIR:-/tmp}"
  fi
  printf '%s/claude-code-hooks/tree-snapshots' "$base"
}

# Snapshot file for a given repository root.
#
# The key is the root path with '/' replaced by '%'. A hash would be shorter,
# but sha256sum is not guaranteed present and a hook that depends on an
# optional binary is a hook that silently stops working on one machine. The
# readable key also lets a human `ls` the directory and see which tree each
# file belongs to when debugging why the stop hook said nothing.
hooks_snapshot_file() {
  local root="${1:-}"
  [ -n "$root" ] || return 1
  printf '%s/%s.snapshot' "$(hooks_snapshot_dir)" "${root//\//%}"
}

# Every path git currently considers dirty in $1, one per line, sorted.
#
# --porcelain leaves core.quotePath at its default, so a path with a newline or
# a non-ASCII byte comes back C-quoted on a single line. That is what makes
# line-oriented set arithmetic safe here; -z would be NUL-clean but then the
# two hooks would need a NUL-aware differ for no gain. -uall lists untracked
# files individually instead of collapsing them to a directory name, so a new
# file inside an existing untracked directory is still named.
#
# A rename record is `R  old -> new`; both sides are emitted, because a path
# that only appears as the source of a rename is still a dirty path.
hooks_dirty_paths() {
  local root="${1:-}" line p
  [ -n "$root" ] || return 1
  git -C "$root" status --porcelain -uall 2>/dev/null | while IFS= read -r line; do
    p="${line:3}"
    case "$p" in
      *" -> "*)
        printf '%s\n' "${p%% -> *}"
        printf '%s\n' "${p##* -> }"
        ;;
      *) printf '%s\n' "$p" ;;
    esac
  done | LC_ALL=C sort -u
}

# Every dirty path in $1 as "<blob-hash> <path>", one per line.
#
# The hash is what makes .githooks/pre-commit able to answer the only question
# that matters: is this staged file byte-identical to what was already sitting
# dirty in the tree before this session started? A path list alone cannot tell
# "foreign, untouched" from "foreign, then edited by me", and the second one is
# legitimately this session's work.
#
# A path that does not exist (a deletion, or a C-quoted exotic name that this
# line-oriented format cannot address) records "-". A "-" never equals a real
# blob hash, so such a path is never blocked - fail-open for exotic filenames,
# stated plainly rather than papered over.
hooks_dirty_entries() {
  local root="${1:-}" p h
  [ -n "$root" ] || return 1
  hooks_dirty_paths "$root" | while IFS= read -r p; do
    h="-"
    if [ -e "$root/$p" ] || [ -L "$root/$p" ]; then
      h="$(git -C "$root" hash-object -- "$p" 2>/dev/null)" || h="-"
      [ -n "$h" ] || h="-"
    fi
    printf '%s %s\n' "$h" "$p"
  done
}

# Value of a `key value` header line in snapshot file $1.
hooks_snapshot_meta() {
  local file="${1:-}" key="${2:-}"
  [ -f "$file" ] || return 1
  sed -n "s/^${key} //p" "$file" | head -1
}

# The "<hash> <path>" entries of snapshot file $1 (everything after `paths`).
hooks_snapshot_entries() {
  local file="${1:-}"
  [ -f "$file" ] || return 1
  sed -n '/^paths$/,$p' "$file" | tail -n +2
}

# Write the baseline for repository $1, tagged with session id $2.
#
# Lives here rather than in session-snapshot.sh because stop-uncommitted.sh
# also needs it: a Stop that finds no baseline seeds one, so the NEXT session
# in this tree is not equally blind. Seeding late is conservative on purpose -
# whatever is dirty right now becomes "was already here", which is the reading
# that cannot cause somebody else's work to be committed.
#
# Returns non-zero and leaves nothing behind if it cannot write. A snapshot is
# renamed into place, never written in place: a reader that caught a half
# written file would classify this session's own work as foreign.
hooks_write_snapshot() {
  local root="${1:-}" session="${2:-unknown}" snap tmp head branch
  [ -n "$root" ] || return 1
  snap="$(hooks_snapshot_file "$root")" || return 1
  mkdir -p "$(dirname "$snap")" 2>/dev/null || return 1

  # `rev-parse HEAD` fails on an unborn branch rather than printing anything,
  # and symbolic-ref fails on a detached HEAD. Both are ordinary states.
  head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head" ] || head="UNBORN"
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -n "$branch" ] || branch="DETACHED"

  tmp="$snap.$$"
  {
    echo "# claude-code tree snapshot v1 - .claude/hooks/_snapshot-common.sh"
    echo "# NOT IN THE REPOSITORY ON PURPOSE: a snapshot inside the tree would"
    echo "# show up as an untracked file and eventually be committed."
    echo "root $root"
    echo "head $head"
    echo "branch $branch"
    echo "epoch $(date +%s 2>/dev/null || echo 0)"
    echo "session $session"
    echo "paths"
    hooks_dirty_entries "$root"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }

  mv -f "$tmp" "$snap" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}
