#!/usr/bin/env bash
# Vendor the upstream superpowers skills into .claude/skills/ so every session -
# local or cloud - discovers them and can invoke one from task context.
#
# Skills are copied with exactly one transformation, applied here and nowhere
# else: upstream writes cross-references plugin-qualified, as
# `superpowers:using-git-worktrees`. We install the skills unqualified, so that
# name resolves to nothing and the handoff dies mid-task. The prefix is stripped.
#
# Do not hand-edit .claude/skills/; edit this script and re-run, or the next
# refresh silently reverts you. A rule that is ours and not upstream's belongs
# in AGENT-CONTRACT.md.
#
# Usage:
#   bash scripts/vendor-skills.sh           # refresh + rewrite the manifest
#   bash scripts/vendor-skills.sh --check   # fail on upstream drift or local edits
set -euo pipefail

REF="${SUPERPOWERS_REF:-master}"
BASE="https://raw.githubusercontent.com/obra/superpowers/${REF}/skills"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/.claude/skills"
MANIFEST="$DEST/MANIFEST.sha256"

# The five skills we route to, plus the four they hand off to. A handoff to a
# skill that is not present is a dead end mid-task, so the closure is vendored
# whole rather than the seed set alone.
FILES=(
  writing-plans/SKILL.md
  executing-plans/SKILL.md
  subagent-driven-development/SKILL.md
  systematic-debugging/SKILL.md
  test-driven-development/SKILL.md
  using-git-worktrees/SKILL.md
  finishing-a-development-branch/SKILL.md
  requesting-code-review/SKILL.md
  verification-before-completion/SKILL.md
  requesting-code-review/code-reviewer.md
  subagent-driven-development/implementer-prompt.md
  subagent-driven-development/task-reviewer-prompt.md
  subagent-driven-development/re-review-prompt.md
)

# The one transformation. Anchored to `superpowers:<skill-name>` so it cannot
# touch prose ("Superpowers works better with...") or paths that merely contain
# the word.
normalize() { sed -E 's/\bsuperpowers:([a-z][a-z0-9-]*)/\1/g' "$1"; }

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
for f in "${FILES[@]}"; do
  mkdir -p "$TMP/up/$(dirname "$f")"
  code=$(curl -fsS --retry 3 --retry-delay 2 -o "$TMP/up/$f" -w '%{http_code}' "$BASE/$f" || echo 000)
  if [ "$code" != "200" ] || [ ! -s "$TMP/up/$f" ]; then
    echo "FETCH FAILED ($code): $BASE/$f" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "refusing to write a partial skill set" >&2; exit 1; }

# Normalized copy, from which both the vendored tree and the local hashes come.
for f in "${FILES[@]}"; do
  mkdir -p "$TMP/norm/$(dirname "$f")"
  normalize "$TMP/up/$f" > "$TMP/norm/$f"
done

up_hashes()   { ( cd "$TMP/up"   && sha256sum "${FILES[@]}" ); }
norm_hashes() { ( cd "$TMP/norm" && sha256sum "${FILES[@]}" ); }

if [ "$CHECK" -eq 1 ]; then
  [ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST - run without --check first" >&2; exit 1; }
  rc=0
  # Upstream drift: did obra/superpowers change under us?
  if ! diff -q <(sed -n '/^\[upstream\]$/,/^\[local\]$/p' "$MANIFEST" | grep -E '^[0-9a-f]{64} ') <(up_hashes) >/dev/null; then
    echo "skills: UPSTREAM DRIFTED - run 'bash scripts/vendor-skills.sh' to refresh" >&2
    rc=1
  fi
  # Local edits: did someone hand-edit the vendored tree?
  if ! ( cd "$DEST" && sha256sum -c --quiet <(sed -n '/^\[local\]$/,$p' "$MANIFEST" | grep -E '^[0-9a-f]{64} ') ) 2>/dev/null; then
    echo "skills: VENDORED TREE EDITED - .claude/skills is not what upstream says" >&2
    rc=1
  fi
  [ "$rc" -eq 0 ] && echo "skills: current with obra/superpowers@$REF, tree unmodified"
  exit "$rc"
fi

mkdir -p "$DEST"
for f in "${FILES[@]}"; do
  mkdir -p "$DEST/$(dirname "$f")"
  cp "$TMP/norm/$f" "$DEST/$f"
done

{
  echo "# obra/superpowers@$REF - vendored by scripts/vendor-skills.sh on $(date -u +%Y-%m-%d)"
  echo "# The API and codeload hosts are blocked from agent sessions, so upstream is"
  echo "# pinned by content hash rather than by commit sha."
  echo "# [upstream] = bytes as served. [local] = after the superpowers: prefix strip."
  echo "# Verify both: bash scripts/vendor-skills.sh --check"
  echo "[upstream]"
  up_hashes
  echo "[local]"
  norm_hashes
} > "$MANIFEST"

echo "vendored ${#FILES[@]} files into ${DEST#"$ROOT"/}"
