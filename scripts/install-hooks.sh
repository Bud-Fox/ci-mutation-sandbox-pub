#!/usr/bin/env bash
#
# Arm the pre-push gate. Run once per clone - including every fresh container.
#
# Two things happen here, and the second is the point:
#   1. git is pointed at the tracked .githooks directory, so the hook travels
#      with the repository instead of living in one person's local config.
#   2. a cached .preflight-venv is built with THIS repository's dependencies.
#      Without it preflight can only skip the test stage, and a gate that skips
#      the expensive check is a gate that catches the cheap defects only. Paying
#      the setup cost here - once, at arm time - is what makes the local run and
#      the CI run agree.
#
# PREFLIGHT_PYTHON=/path/to/python overrides which interpreter builds the venv;
# the default is python3.12 (CI's), see the selection below.
#
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

echo "== pointing git at the tracked hooks directory"
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/preflight.sh scripts/install-deps.sh 2>/dev/null || true
echo "   core.hooksPath = .githooks"

echo
echo "== building .preflight-venv with this repository's dependencies"

# WHICH python builds the venv. CI runs 3.12, and a venv built with whatever
# `python3` happens to be the newest on the machine is a different environment
# from CI's: on 2026-10-17 python3 was 3.14.6, pydantic-core has no 3.14 wheel and
# PyO3 0.24.1 refuses 3.14, so every extra failed to install. In order:
#   1. $PREFLIGHT_PYTHON, if set and executable;
#   2. the first of python3.12, python3.13, python3.11 - on PATH, else under
#      `brew --prefix python@X.Y`/bin (a Homebrew python is often off PATH);
#   3. python3, loudly, because nothing says it can install this repository.
py_version() { "$1" --version 2>&1 | sed -n -E 's/^Python ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1; }
py_minor()   { py_version "$1" | sed -n -E 's/^([0-9]+\.[0-9]+).*/\1/p'; }

PY_CHOSEN=""; PY_WHY=""
if [ -n "${PREFLIGHT_PYTHON:-}" ]; then
  if p=$(command -v "$PREFLIGHT_PYTHON" 2>/dev/null) && [ -x "$p" ]; then
    PY_CHOSEN="$p"; PY_WHY="PREFLIGHT_PYTHON"
  else
    echo "   WARNING: PREFLIGHT_PYTHON=$PREFLIGHT_PYTHON is not an executable - ignoring it"
  fi
fi
if [ -z "$PY_CHOSEN" ]; then
  for minor in 3.12 3.13 3.11; do
    if p=$(command -v "python$minor" 2>/dev/null) && [ -x "$p" ]; then
      PY_CHOSEN="$p"; PY_WHY="python$minor on PATH"; break
    fi
    if command -v brew >/dev/null 2>&1; then
      prefix=$(brew --prefix "python@$minor" 2>/dev/null)
      if [ -n "$prefix" ] && [ -x "$prefix/bin/python$minor" ]; then
        PY_CHOSEN="$prefix/bin/python$minor"; PY_WHY="brew python@$minor"; break
      fi
    fi
  done
fi
if [ -z "$PY_CHOSEN" ]; then
  if p=$(command -v python3 2>/dev/null) && [ -x "$p" ]; then
    PY_CHOSEN="$p"; PY_WHY="fallback: python3"
    if [ "$(py_minor "$p")" != "3.12" ]; then
      echo "   WARNING: no python3.12, python3.13 or python3.11 found; falling back to python3 = $(py_version "$p")."
      echo "   CI runs 3.12; a dependency with no wheel for this version fails to install here and not there."
      echo "   Install one (brew install python@3.12) or set PREFLIGHT_PYTHON=/path/to/python3.12."
    fi
  else
    echo "   no python found on PATH (tried PREFLIGHT_PYTHON, python3.12, python3.13, python3.11, python3)."
    echo "   The gate still runs; it will SKIP the test stage and say so."
    exit 0
  fi
fi
echo "   venv python: $PY_CHOSEN ($(py_version "$PY_CHOSEN"))"
echo "   chosen via: $PY_WHY"

# An existing venv is reused only if it was built by the same major.minor.
# Reusing one built by another python is how a venv outlives the fix above.
if [ -x .preflight-venv/bin/python ]; then
  have=$(py_minor .preflight-venv/bin/python); want=$(py_minor "$PY_CHOSEN")
  if [ -n "$have" ] && [ "$have" = "$want" ]; then
    echo "   already present (python $have) - reusing (delete the directory to start over)"
  else
    echo "   existing .preflight-venv was built with python ${have:-unknown}, chosen is python ${want:-unknown} - rebuilding"
    rm -rf .preflight-venv
  fi
fi
if [ ! -x .preflight-venv/bin/python ]; then
  if ! "$PY_CHOSEN" -m venv .preflight-venv 2>/dev/null; then
    echo "   could not create a venv with $PY_CHOSEN (python3-venv missing?)."
    echo "   The gate still runs; it will SKIP the test stage and say so."
    exit 0
  fi
fi
V=.preflight-venv/bin/python

# The gate's tooling and this repository's dependencies, from the ONE script
# that also does it in CI. It used to be spelled out here and again in
# .github/workflows/_preflight.yml, under a comment in capital letters asking
# the two to stay identical; they had already drifted. See scripts/install-deps.sh.
#
# The fallback is the same one _preflight.yml uses for the gate itself: a repo
# that has not synced the new script yet still gets armed properly rather than
# silently arming a gate with no tooling behind it.
if [ -f scripts/install-deps.sh ]; then
  bash scripts/install-deps.sh "$V" | sed 's/^/   /'
else
  echo "   scripts/install-deps.sh is missing here - using the copy in Bud-Fox/.github."
  echo "   Run scripts/sync.sh from that repository to adopt it properly."
  curl -fsSL https://raw.githubusercontent.com/Bud-Fox/.github/main/scripts/install-deps.sh \
    | bash -s -- "$V" | sed 's/^/   /'
fi

# Never commit the cache. A repository with no .gitignore at all is the case
# where committing it is most likely, so create the file rather than skip.
[ -f .gitignore ] || : > .gitignore
if ! grep -qxF '.preflight-venv/' .gitignore; then
  printf '\n# Local cache built by scripts/install-hooks.sh - never committed.\n.preflight-venv/\n' >> .gitignore
  echo "   added .preflight-venv/ to .gitignore"
fi

echo
echo "== verifying the gate runs"
if bash scripts/preflight.sh >/tmp/preflight-arm.log 2>&1; then
  echo "   PASS - pre-push is armed."
else
  echo "   The gate ran and reported findings. Full output: /tmp/preflight-arm.log"
  echo "   It is armed either way; fix the findings before your next push."
fi
