#!/usr/bin/env bash
#
# Install everything the preflight gate needs, for ONE interpreter.
#
#   bash scripts/install-deps.sh <python-executable> [extra pip args...]
#
# THE SAME FILE runs in both places that install:
#   1. scripts/install-hooks.sh          -> the cached .preflight-venv
#   2. .github/workflows/_preflight.yml  -> the CI runner's python
#
# WHY IT IS ITS OWN FILE
# ----------------------
# preflight SKIPS its test stage when the repository's dependencies are absent
# (a gate must not fail on the state of the machine it runs on), so whichever
# call site installs less quietly checks less - and says PASS while doing it.
# The two used to be two hand-kept copies of this cascade with a comment
# between them in capital letters demanding they stay identical. They did not:
# CI grew an extra-packages escape hatch the local installer never got, so a
# repository needing one more package had it in CI and not locally - the exact
# local/CI asymmetry both files' headers exist to prevent. A comment cannot
# enforce that. One file can.
#
# PER-REPOSITORY FACTS LIVE IN THE REPOSITORY
# -------------------------------------------
# The optional .preflight.conf at the repository root is read here as well as
# by preflight itself. Recognised here:
#
#   PREFLIGHT_EXTRA_REQUIREMENTS   space-separated requirements files to install
#                                  in addition to the main manifest, e.g.
#                                  "contabo_mcp/requirements.txt src/requirements.txt"
#   PREFLIGHT_SKIP_EXTRAS          space-separated names from
#                                  [project.optional-dependencies] NOT to
#                                  install, for an extra that is genuinely
#                                  unwanted here (a GPU wheel, a platform-only
#                                  package). Everything else is installed.
#
# Those two paths were hardcoded in both copies of this cascade, which meant
# every repository in the org carried a line about one repository's layout.
#
set -uo pipefail

PY="${1:-}"
if [ -z "$PY" ]; then
  echo "install-deps: usage: install-deps.sh <python-executable> [extra pip args...]" >&2
  exit 2
fi
shift

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

PREFLIGHT_EXTRA_REQUIREMENTS="${PREFLIGHT_EXTRA_REQUIREMENTS:-}"
if [ -f .preflight.conf ]; then
  set -a; . ./.preflight.conf; set +a
fi

# pip's own output is collected rather than shown. Most failures here are
# EXPECTED - the cascade below tries `.[dev]` first precisely so it can fall
# through to `.` - and printing a traceback for each attempt trains everyone to
# ignore the whole block. The log is printed if NOTHING installed, which is the
# case where the reason matters.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
pip_install() { "$PY" -m pip install --quiet "$@" >>"$LOG" 2>&1; }

INSTALLED=""
note() { INSTALLED="${INSTALLED:+${INSTALLED} }$1"; echo "installed: $1"; }

pip_install --upgrade pip

# The gate's own tooling. The shellcheck-py wheel ships the ShellCheck binary,
# so preflight's shell stages are real wherever this ran - or decorative in
# whichever call site got left behind, back when there were two of these.
if pip_install pyyaml pytest pytest-timeout shellcheck-py; then
  echo "installed: gate tooling (pyyaml pytest pytest-timeout shellcheck-py)"
else
  echo "WARNING: could not install the gate tooling (offline?)"
fi

# ---------------------------------------------------------------------------
# EVERY manifest the repository declares, and every extra - not the first one
# that happens to work.
#
# This was a cascade: `.[dev]`, else `.`, else requirements-dev.txt, else
# requirements.txt. One branch won and the rest were never read, so a
# repository that declares its test-time needs anywhere but the winning branch
# got a strictly smaller environment than its author has. The gate then ran the
# test suite against that smaller environment and reported the difference as a
# failing test.
#
# Observed, not theorised: ru-find-cadastre declares Pillow under the `maps`
# extra, with a comment explaining that without it `object_map` answers
# `renderer_unavailable` rather than pretending the map does not exist. The
# cascade installed `.[dev]` and stopped, so five tests that assert on the
# rendered output failed in CI - on a machine state, not on anybody's change.
# That is precisely the failure this gate's own header says a gate must not
# have, and the author sees it as a red cross on work that has nothing to do
# with maps.
#
# An extra exists to be optional at RUNTIME. At TEST time the suite is the
# declaration of what is needed, and a suite that exercises an extra needs it
# installed. So the default is all of them, and a repository with a genuinely
# unwanted extra names it in PREFLIGHT_SKIP_EXTRAS rather than everybody else
# carrying a guess about which extra names mean "test" this week.
# ---------------------------------------------------------------------------
list_extras() {
  "$PY" - <<'PY' 2>/dev/null
import re, sys

try:
    import tomllib
except ModuleNotFoundError:                      # python < 3.11
    try:
        import tomli as tomllib                  # type: ignore[no-redef]
    except ModuleNotFoundError:
        tomllib = None

names = []
if tomllib is not None:
    try:
        with open("pyproject.toml", "rb") as fh:
            doc = tomllib.load(fh)
        names += list((doc.get("project") or {}).get("optional-dependencies") or {})
        names += list(((doc.get("tool") or {}).get("poetry") or {}).get("extras") or {})
    except Exception:
        names = []

if not names:
    # No toml parser, or a file this one could not read. A shallow scan of the
    # one section beats reporting no extras at all, and a wrong name here only
    # costs a pip install that fails and is tolerated.
    try:
        text = open("pyproject.toml", encoding="utf-8").read()
    except OSError:
        sys.exit(0)
    section = re.split(r"^\[project\.optional-dependencies\]\s*$", text, maxsplit=1, flags=re.M)
    if len(section) == 2:
        for line in section[1].splitlines():
            if re.match(r"^\[", line):
                break
            m = re.match(r'^\s*([A-Za-z0-9_.-]+)\s*=', line)
            if m:
                names.append(m.group(1))

for n in dict.fromkeys(names):
    print(n)
PY
}

PREFLIGHT_SKIP_EXTRAS="${PREFLIGHT_SKIP_EXTRAS:-}"

if [ -f pyproject.toml ]; then
  if pip_install -e "."; then note 'pyproject "."'; fi

  EXTRAS=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    SKIP=0
    for s in $PREFLIGHT_SKIP_EXTRAS; do [ "$name" = "$s" ] && SKIP=1; done
    [ "$SKIP" -eq 1 ] && { echo "skipped extra (PREFLIGHT_SKIP_EXTRAS): $name"; continue; }
    EXTRAS+=("$name")
  done < <(list_extras)

  if [ "${#EXTRAS[@]}" -gt 0 ]; then
    # One resolve for all of them first, because that is much faster and is
    # what succeeds nearly always. Falling back to one at a time matters when a
    # single extra cannot resolve on this platform: it should cost that extra,
    # not every other one.
    ALL=$(IFS=,; echo "${EXTRAS[*]}")
    if pip_install -e ".[$ALL]"; then
      note "pyproject extras \"$ALL\""
    else
      echo "the extras did not resolve together - installing them one at a time"
      for name in "${EXTRAS[@]}"; do
        if pip_install -e ".[$name]"; then
          note "pyproject extra \"$name\""
        else
          echo "WARNING: extra \"$name\" did not install - a test that needs it will fail"
        fi
      done
    fi
  fi
fi

# Dependency GROUPS - Poetry's [tool.poetry.group.*.dependencies] and
# [tool.poetry.dev-dependencies], PEP 735 [dependency-groups]. They are not
# extras, so `pip install -e ".[...]"` never sees them, and they are exactly
# where a repository keeps ruff and mypy. Without them preflight's workflow-
# commands stage skips `poetry run mypy` by name, and a mypy error CI will fail
# on (msk-capintel 4ca33b4: cli.py importing a module not yet committed)
# leaves the machine. Poetry constraints (^1.2, ~0.6) are not PEP 508, so its
# groups install by NAME only; PEP 735 entries are PEP 508 and go as written.
list_groups() {
  "$PY" - <<'PY' 2>/dev/null
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore[no-redef]
doc = tomllib.load(open("pyproject.toml", "rb"))
poetry = (doc.get("tool") or {}).get("poetry") or {}
out = []
tables = [g.get("dependencies") or {} for g in (poetry.get("group") or {}).values()]
tables.append(poetry.get("dev-dependencies") or {})
for t in tables:
    out += [n for n in t if n.lower() != "python"]
for items in (doc.get("dependency-groups") or {}).values():
    out += [i for i in items if isinstance(i, str)]
for n in dict.fromkeys(out):
    print(n)
PY
}
if [ -f pyproject.toml ]; then
  GROUPS_DEPS=()
  while IFS= read -r dep; do [ -n "$dep" ] && GROUPS_DEPS+=("$dep"); done < <(list_groups)
  if [ "${#GROUPS_DEPS[@]}" -gt 0 ]; then
    if pip_install "${GROUPS_DEPS[@]}"; then note "dependency groups (${#GROUPS_DEPS[@]})"
    else echo "WARNING: dependency groups did not install together - a tool CI runs may be skipped"; fi
  fi
fi

# Both, when a repository declares both. requirements-dev.txt conventionally
# starts with `-r requirements.txt`, in which case installing both costs one
# no-op; when it does not, the elif that used to be here was silently dropping
# the base requirements.
if [ -f requirements-dev.txt ] && pip_install -r requirements-dev.txt; then note "requirements-dev.txt"; fi
if [ -f requirements.txt ]     && pip_install -r requirements.txt;     then note "requirements.txt"; fi

read -r -a EXTRA_REQS <<<"$PREFLIGHT_EXTRA_REQUIREMENTS"
for extra in "${EXTRA_REQS[@]:-}"; do
  [ -n "$extra" ] || continue
  if [ -f "$extra" ] && pip_install -r "$extra"; then note "$extra"; fi
done

# Anything the caller asked for on top (CI passes the reusable workflow's
# `install` input through here).
if [ "$#" -gt 0 ]; then
  if pip_install "$@"; then note "$*"; else echo "WARNING: could not install: $*"; fi
fi

if [ -z "$INSTALLED" ]; then
  echo "no installable manifest found - preflight will name the stages it skipped"
  if [ -s "$LOG" ]; then tail -20 "$LOG" | sed 's/^/  pip: /'; fi
fi

# Never fails. A missing dependency is preflight's to report, as a named SKIP;
# a non-zero exit here would turn it into a red hook before the gate had a
# chance to say which stage it cost.
exit 0
