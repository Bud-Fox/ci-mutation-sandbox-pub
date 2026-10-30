#!/usr/bin/env bash
#
# Canonical pre-push gate. THE SAME FILE runs in two places:
#   1. .githooks/pre-push          (local, armed by scripts/install-hooks.sh)
#   2. the single step of Bud-Fox/.github/.github/workflows/_preflight.yml
# Add a check HERE, never in a workflow yaml. The moment CI runs a check the
# local hook does not, the guarantee this file exists for is gone.
#
# THE ONE RULE THAT KEEPS IT ALIVE
# -------------------------------
# The gate fails on what the AUTHOR changed. It never fails on the state of the
# machine it happens to run on. A hook that goes red because a library is not
# installed gets bypassed with --no-verify within a day, and then it protects
# nothing. So every check here is one of:
#   RUN   - the tools it needs are present, the result is trustworthy
#   SKIP  - the tools are absent; say so by name and do not fail
# The first version of this file broke that rule and failed five of seven
# repositories on ModuleNotFoundError. That is why the distinction is explicit.
#
# CONVENTIONS ARE DETECTED, NOT ASSUMED
# -------------------------------------
# One repository numbers migrations 20260817120000_, another numbers them 001_.
# Both are correct. A shared gate that hardcodes one of them is wrong in every
# repository that chose the other, so the dominant convention is measured from
# the files already in the tree and only NEW files are held to it.
#
# PER-REPOSITORY FACTS LIVE IN THE REPOSITORY
# -------------------------------------------
# An optional .preflight.conf at the repository root is sourced before the run.
# It is the one place a repository states something only it can know, and it is
# never a reason to edit this shared file. Recognised keys:
#
#   PREFLIGHT_PYTEST_ARGS   extra pytest arguments, e.g. to deselect a suite
#                           that needs live API credentials
#   PREFLIGHT_SKIP_TESTS=1  skip the test stage entirely
#   PREFLIGHT_EXTRA_REQUIREMENTS
#                           space-separated requirements files scripts/install-deps.sh
#                           installs alongside the main manifest, e.g.
#                           "contabo_mcp/requirements.txt src/requirements.txt".
#                           Read by that script, not by this one.
#
# ENVIRONMENT
#   .preflight-venv/     created once by scripts/install-hooks.sh; used if present
#   PREFLIGHT_SKIP_TESTS=1   skip the test stage (a genuinely slow suite)
#   PREFLIGHT_VERBOSE=1      show full output of a failing stage
#
set -uo pipefail

FAIL=0
SKIPPED=""
WARNED=""
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

# BUD-LOCK-BEGIN: before any check can read or mutate this clone.
# A session exports one identity through preflight and nested Git hooks.
export BUD_LOCK_OWNER="${BUD_LOCK_OWNER:-${HERMES_SESSION_ID:-${USER:-unknown}@$(hostname -s):$PPID}}"
LEASE_SCRIPT="$ROOT/scripts/bud-lock.sh"
if [ ! -f "$LEASE_SCRIPT" ]; then
  LEASE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/bud-lock.sh"
fi
if [ ! -f "$LEASE_SCRIPT" ]; then
  echo "BUD-LOCK: missing bud-lock.sh - sync/install the complete gate; refusing unleased preflight" >&2
  exit 1
fi
# Cleanup belongs to this invocation, not to a persistent runner checkout.
# Parent-owned leases remain held. A unique acquired identity and owner-only
# release prevent deleting replacement leases, even when they are expired.
WORK=""
SCOPE=""
SCOPE_OWNER=""
cleanup_preflight() {
  local rc=$? owned=1
  trap - EXIT INT TERM
  if [ -n "$SCOPE" ]; then
    owned=$(printf '%s' "$SCOPE" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["owned"]))')
  fi
  if [ -n "$SCOPE_OWNER" ] && [ "$owned" = 1 ]; then
      if ! BUD_LOCK_OWNER="$SCOPE_OWNER" bash "$LEASE_SCRIPT" release-owned; then
        echo "BUD-LOCK: scoped cleanup failed; lease retained for explicit recovery/TTL" >&2
        [ "$rc" = 0 ] && rc=1
      fi
  fi
  [ -z "$WORK" ] || rm -rf "$WORK"
  exit "$rc"
}
trap cleanup_preflight EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The parent knows its candidate identity BEFORE the helper can write a lease.
# Cleanup therefore works even when cancellation interrupts the JSON handoff.
nonce=$(python3 -c 'import uuid; print(uuid.uuid4().hex)') || exit 1
SCOPE_OWNER="$BUD_LOCK_OWNER/scope-$nonce"
if ! SCOPE=$(BUD_LOCK_SCOPE_OWNER="$SCOPE_OWNER" bash "$LEASE_SCRIPT" acquire-scoped); then
  echo "BUD-LOCK: preflight refused before checks" >&2
  exit 1
fi
export BUD_LOCK_OWNER
BUD_LOCK_OWNER=$(printf '%s' "$SCOPE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["owner"],end=".")') || exit 1
BUD_LOCK_OWNER=${BUD_LOCK_OWNER%.}
# BUD-LOCK-END

# Every stage's captured output lives here, and it goes away when the run does.
# These were fixed /tmp/pf.* names, so two runs in one container - the hook and
# a hand-run of the gate, or two agents in the same box - overwrote each other's
# evidence while the first was still reading it. Same pattern as host-deploy.sh.
WORK="$(mktemp -d)"

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else B=""; R=""; G=""; Y=""; N=""; fi

say()  { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
ok()   { printf '  %sok%s   %s\n'   "$G" "$N" "$1"; }
bad()  { printf '  %sFAIL%s %s\n'   "$R" "$N" "$1"; FAIL=1; }
skip() { printf '  %sskip%s %s\n'   "$Y" "$N" "$1"; SKIPPED="${SKIPPED}\n  - $1"; }
# A real finding that this push is not answerable for: the file it is in was
# already like that before the branch left the trunk. Reported with its file and
# line like any other, and listed in the summary the way a skip is, because a
# finding nobody is ever shown is the same as no gate at all for that file.
warn() { printf '  %swarn%s %s\n'   "$Y" "$N" "$1"; WARNED="${WARNED}\n  - $1"; }
have() { command -v "$1" >/dev/null 2>&1; }
# The evidence under a FAIL line, indented to sit beneath it and capped so one
# broken file cannot bury the other stages. Which end to keep is per stage and
# deliberate: a compiler or linter puts the first defect first, a test runner
# puts the summary last. That was eight hand-written pipelines with eight
# hand-picked caps, and the indent had already been typed out eight times.
detail()      { sed 's/^/       /' "$1" | head -n "$2"; }   # the first n lines
detail_last() { tail -n "$2" "$1" | sed 's/^/       /'; }   # the last n lines

# Prefer the cached venv the hook installer builds, so the local run has the
# repository's own dependencies and its result matches CI.
PY=python3
if [ -x "$ROOT/.preflight-venv/bin/python" ]; then
  PY="$ROOT/.preflight-venv/bin/python"
  export PATH="$ROOT/.preflight-venv/bin:$PATH"
fi
pymod() { "$PY" -c "import $1" >/dev/null 2>&1; }

# Repository-local settings, if the repository declares any.
PREFLIGHT_PYTEST_ARGS="${PREFLIGHT_PYTEST_ARGS:-}"
if [ -f "$ROOT/.preflight.conf" ]; then
  set -a; . "$ROOT/.preflight.conf"; set +a
fi

SRC_FILTER=(-not -path './.git/*' -not -path '*/.venv/*' -not -path '*/.preflight-venv/*'
            -not -path '*/node_modules/*' -not -path '*/site-packages/*' -not -path '*/build/*')

# Where this branch left the trunk. Every stage that asks "what did the AUTHOR
# change" needs it, and each of them used to work it out again - stage 3 falling
# back to origin/HEAD, stage 6 not. In a repository whose trunk is not called
# main but whose origin/HEAD resolves, that meant stage 3 ran and stage 6 quietly
# skipped: the same question, two answers. Empty is the honest answer in a
# shallow clone with no origin, and both stages already say so by name.
BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/HEAD 2>/dev/null || echo "")

# WHAT THIS PUSH CHANGED - the scope the per-file stages are judged against.
# Derived from BASE above, once, for the same reason BASE itself is: three
# stages asking the same question separately is three chances to answer it
# differently.
#
# WHY THIS EXISTS. Stages 1, 2b, 2c and 2d walk the whole tree, which is right -
# they have to see a file to inspect it. What they must not do is fail the
# pusher for a defect that was already there. Distributed to 47 repositories,
# this gate failed 17 of them on first contact, every single one on a finding in
# a file the pusher never opened: an SC2164 in an import script, a swallowed
# status in a deploy script written months earlier. With .githooks/pre-push
# returning this script's status straight to git, that is not a warning, it is
# an agent that cannot push at all. It is the same failure stage 2c's severity
# policy was written to prevent, arriving along the scope axis instead of the
# severity axis, and it earns --no-verify just as fast.
#
# Uncommitted and untracked files count as this push's. They are certainly not
# what the trunk already had, and a defect the author is one `git commit` away
# from pushing should fail now, not on the next run.
#
# AN UNKNOWN SCOPE IS STRICT, NOT EMPTY. In a shallow clone with no origin there
# is no merge-base and no way to tell new from existing, so every file counts as
# this push's and nothing is downgraded. Treating "cannot compute" as "nothing
# is mine" would turn a missing remote into a silent bypass of four stages; the
# stages say the scope is unknown on their own line instead.
SCOPE_KNOWN=1
CHANGED_LIST="$WORK/changed-files"
: >"$CHANGED_LIST"
if [ -n "$BASE" ]; then
  { git diff --name-only "$BASE" HEAD
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
  } 2>/dev/null | sort -u >"$CHANGED_LIST"
else
  SCOPE_KNOWN=0
fi
SCOPE_NOTE=""
[ "$SCOPE_KNOWN" -eq 1 ] || SCOPE_NOTE=" [scope unknown: no merge-base, every file counts as this push's]"
# Read by pfwalk.py, so stages 2b and 2d scope against the same list as 1 and 2c.
export PREFLIGHT_SCOPE_KNOWN="$SCOPE_KNOWN" PREFLIGHT_CHANGED_LIST="$CHANGED_LIST"

# `find` prints ./x/y.py and git prints x/y.py. Normalised here, once, rather
# than at each call site - stage 1 is the one that feeds find's paths in, and a
# leading ./ left on would make every python file look untouched.
changed() {
  [ "$SCOPE_KNOWN" -eq 1 ] || return 0
  grep -qxF "${1#./}" "$CHANGED_LIST"
}

# Does this push touch the test suite? Read by the tests stage: owner decision
# A (2026-10-20, decision-board card) makes an empty or uncollectable pytest
# suite an ADVISORY - but only when the push edits no test file. A push that
# edits tests while the suite collects nothing stays red (protection against
# deleting the suite from a repository that had one). Scope unknown (no
# merge-base) counts as touched: the gate cannot prove the push did not edit
# tests, and fail-closed is the gate's standing rule.
tests_touched() {
  [ "$SCOPE_KNOWN" -eq 1 ] || return 0
  grep -Eq '(^|/)tests?/' "$CHANGED_LIST" || \
  grep -Eq '(^|/)(test_[^/]*|[^/]*_test|conftest)\.py$' "$CHANGED_LIST"
}

# ---------------------------------------------------------------- 1. syntax --
say "python syntax"
mapfile -t PYF < <(find . -name '*.py' "${SRC_FILTER[@]}" -print 2>/dev/null)
if [ ${#PYF[@]} -eq 0 ]; then
  ok "no python files"
else
  # Split the population and compile each half, rather than compiling
  # everything and sorting the errors out afterwards. py_compile names the file
  # it choked on in prose; recovering a path from that string is the mistake
  # this file avoids everywhere else.
  PY_MINE=(); PY_PRE=()
  for f in "${PYF[@]}"; do
    if changed "$f"; then PY_MINE+=("$f"); else PY_PRE+=("$f"); fi
  done
  PY_CLEAN=1
  if [ ${#PY_MINE[@]} -gt 0 ] && ! "$PY" -m py_compile "${PY_MINE[@]}" 2>"$WORK/py.err"; then
    bad "py_compile${SCOPE_NOTE}"; detail "$WORK/py.err" 20; PY_CLEAN=0
  fi
  if [ ${#PY_PRE[@]} -gt 0 ] && ! "$PY" -m py_compile "${PY_PRE[@]}" 2>"$WORK/py-pre.err"; then
    warn "py_compile: pre-existing, in file(s) this push did not change"
    detail "$WORK/py-pre.err" 20; PY_CLEAN=0
  fi
  if [ "$PY_CLEAN" -eq 1 ]; then
    ok "${#PYF[@]} file(s) compile${SCOPE_NOTE}"
  fi
fi

# ------------------------------------------------------------------ 2. yaml --
say "yaml syntax"
if ! pymod yaml; then
  skip "yaml: pyyaml not installed (CI installs it; run scripts/install-hooks.sh locally)"
else
  if "$PY" - <<'PY' 2>"$WORK/yaml.err"
import sys, pathlib, yaml
bad = 0
skip_parts = {".git", "node_modules", ".venv", ".preflight-venv", "site-packages"}
for p in list(pathlib.Path(".").rglob("*.yml")) + list(pathlib.Path(".").rglob("*.yaml")):
    if skip_parts & set(p.parts):
        continue
    try:
        list(yaml.safe_load_all(p.read_text()))
    except Exception as e:
        print(f"{p}: {str(e).splitlines()[0][:160]}")
        bad = 1
sys.exit(bad)
PY
  then ok "all yaml parses"
  else bad "yaml does not parse"; detail "$WORK/yaml.err" 15; fi
fi

# --------------------------------------------------- the shellcheck policy --
# ONE definition, read by both stages that run shellcheck: 2b (the `run:` blocks
# of every workflow, via the environment into the python below) and 2c (the
# repository's own scripts). The policy itself - why these two passes and why
# the second one is this narrow - is documented at stage 2c; this is only where
# the two numbers live.
#
# It was written out twice, once in bash and once in python, and the two copies
# had no way to notice each other. Adding a fourth info-level code to one side
# and not the other changed what half the repository was linted for, silently.
SC_SEVERITY=warning                        # pass 1: fail on error and warning
SC_INFO_CODES=SC2015,SC2164,SC2103         # pass 2: fail on exactly these

# WHAT THE SHELL STAGES INSPECT - also one definition.
# Stages 2c and 2d both lint the repository's tracked shell scripts, and both
# used to ask git for the list themselves (once in bash, once in python). Asked
# once, written down, read by both: the stages cannot disagree about which files
# they cover.
mapfile -t SHF < <(git ls-files '*.sh' '.githooks/*' 2>/dev/null)
printf '%s\n' "${SHF[@]:-}" > "$WORK/sh-files"

# The other population is the `run:` blocks of every workflow, and stages 2b and
# 2d used to walk the yaml with two byte-identical copies of the same nested
# loop. One walk, emitted here and imported by both, so a change to what counts
# as a run: block reaches both stages or neither.
cat > "$WORK/pfwalk.py" <<'PFWALK'
"""The two populations the shell stages inspect, walked once.

Every generator yields (path, label, source):
  path    the repository-relative file the finding is in, as git spells it.
          Yielded separately from the label because both callers now have to
          ask whether this push changed it, and a workflow's label is
          "file: job / step" - recovering the path by splitting that string
          works right up until a job or step name contains ": ".
  label   what a finding is printed against - the caller does not build it, so
          two stages reporting the same defect name it the same way
  source  the shell text to inspect, verbatim (substitutions such as 2b's
          GHA_EXPR are the caller's business, because 2d must not make them)
"""
import os
import pathlib


def changed_paths(list_file=None):
    """The files this push changes, as bash worked them out - or None.

    None means bash could not determine the scope (no merge-base). It does NOT
    mean "no file is this push's": a caller that treats it as an empty set
    silently stops enforcing anything in a shallow clone. Every caller must
    read None as "everything counts as this push's".
    """
    if os.environ.get("PREFLIGHT_SCOPE_KNOWN") != "1":
        return None
    list_file = list_file or os.environ.get("PREFLIGHT_CHANGED_LIST", "")
    if not list_file:
        return None
    try:
        return {p for p in pathlib.Path(list_file).read_text().splitlines() if p}
    except OSError:
        return None

try:
    import yaml
except ImportError:                # stage 2b already named this skip by name
    yaml = None


def workflow_runs(directory=".github/workflows"):
    """Every `run:` block of every workflow, in file order."""
    if yaml is None:
        return
    for p in sorted(pathlib.Path(directory).glob("*.y*ml")):
        try:
            doc = yaml.safe_load(p.read_text()) or {}
        except Exception:
            continue               # the yaml stage already reported this
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            for i, step in enumerate(job.get("steps") or []):
                if not isinstance(step, dict) or "run" not in step:
                    continue
                label = step.get("name") or f"step {i}"
                yield str(p), f"{p}: {job_name} / {label}", str(step["run"])


def shell_scripts(list_file=None):
    """The repository's tracked shell scripts, as bash listed them."""
    list_file = list_file or os.environ.get("PREFLIGHT_SH_LIST", "")
    if not list_file:
        return
    try:
        names = pathlib.Path(list_file).read_text().splitlines()
    except OSError:
        return
    for f in names:
        if not f:
            continue
        try:
            yield f, f, pathlib.Path(f).read_text()
        except OSError:
            continue
PFWALK

# ------------------------------------------------- 2b. workflow run: blocks --
# A `run:` block is a shell script that yaml knows nothing about. Valid yaml
# with a broken script inside parses clean here and fails in CI minutes later,
# so each block is extracted and handed to `bash -n` and then to shellcheck.
#
# The common defect this catches: a multi-line shell string whose continuation
# lines start at column 0. That is legal shell and illegal inside a yaml block
# scalar, and the error yaml reports points at a line far from the cause.
#
# WHY SHELLCHECK AND NOT JUST `bash -n`
# `bash -n` answers one question: does this parse. It has nothing to say about
# `A && B || C`, which parses perfectly and silently returns success - the
# defect that shipped an unhealthy deploy as a green build (the full story is
# in stage 2c). The extracted block therefore goes through shellcheck under the
# same two-pass severity policy stage 2c documents.
#
# GHA EXPRESSIONS. `${{ ... }}` is fine for `bash -n` but makes shellcheck emit
# SC1009/SC1073 parse errors, so every expression is replaced by the bare token
# GHA_EXPR before BOTH checks. The token is harmless inside quotes and inside
# constructs like  -d "{\"sha\":\"${{ github.sha }}\"}" . Its one side effect
# is that a test against an expression becomes a test against a literal, so
# SC2050/SC2157 ("this expression is constant") are excluded here: those are
# artefacts of the substitution, not of anything the author wrote.
say "workflow run: blocks"
: >"$WORK/runs.warn"
if [ ! -d .github/workflows ]; then
  ok "no workflows directory"
elif ! pymod yaml; then
  skip "workflow run: blocks: pyyaml not installed"
else
  have shellcheck || \
    skip "workflow run: blocks: shellcheck not installed (run scripts/install-hooks.sh) - bash -n only"
  RUNS_RC=0
  SC_SEVERITY="$SC_SEVERITY" SC_INFO_CODES="$SC_INFO_CODES" PYTHONPATH="$WORK" \
     PREFLIGHT_WARN_OUT="$WORK/runs.warn" \
     "$PY" - <<'PY' 2>"$WORK/runs.err" || RUNS_RC=1
import re, shutil, subprocess, sys, tempfile, os
import pfwalk                                    # the shared walk, emitted above

GHA_EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)
SHELLCHECK = shutil.which("shellcheck")          # absent -> bash -n only, stage says so
# --exclude is 2b's alone: SC2050/SC2157 fire on the GHA_EXPR substitution
# above, not on anything an author wrote. The severities come from the one
# definition in bash, so 2b and 2c cannot enforce different policies.
SC_COMMON = ["--shell=bash", "--exclude=SC2050,SC2157"]
SC_PASSES = [["-S", os.environ["SC_SEVERITY"]],
             ["-S", "info", "--include=" + os.environ["SC_INFO_CODES"]]]

SCOPE = pfwalk.changed_paths()      # None => scope unknown => everything is ours
WARN = open(os.environ["PREFLIGHT_WARN_OUT"], "w")

bad = 0
for path, label, run in pfwalk.workflow_runs():
    src = GHA_EXPR.sub("GHA_EXPR", run)
    fh = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
    fh.write(src); fh.close()
    checks = [["bash", "-n", fh.name]]
    if SHELLCHECK:
        checks += [[SHELLCHECK, *SC_COMMON, *a, fh.name] for a in SC_PASSES]
    for cmd in checks:
        r = subprocess.run(cmd, capture_output=True, text=True)
        if not r.returncode:
            continue
        # A block in a workflow file this push never opened is reported and not
        # enforced - it goes to the warn file instead of stderr, and leaves the
        # exit status alone.
        mine = SCOPE is None or path in SCOPE
        # stderr, so the caller captures it and the FAIL line stays above the
        # detail like every other stage.
        out = sys.stderr if mine else WARN
        print(label, file=out)
        detail = (r.stdout + r.stderr).strip().replace(fh.name, "run")
        for line in detail.splitlines()[:14]:
            print("  " + line[:200], file=out)
        if mine:
            bad = 1
    os.unlink(fh.name)
WARN.close()
sys.exit(bad)
PY
  if [ -s "$WORK/runs.warn" ]; then
    warn "workflow run: blocks: pre-existing, in file(s) this push did not change"
    detail "$WORK/runs.warn" 20
  fi
  if [ "$RUNS_RC" -eq 1 ]; then
    bad "a workflow run: block is bad shell${SCOPE_NOTE}"; detail "$WORK/runs.err" 30
  elif [ ! -s "$WORK/runs.warn" ]; then
    if have shellcheck; then ok "every run: block parses and passes shellcheck${SCOPE_NOTE}"
    else                     ok "every run: block is valid shell${SCOPE_NOTE}"; fi
  fi
fi

# ------------------------------------------------------- 2c. shell scripts --
# ShellCheck over the repository's own scripts.
#
# WHY THIS STAGE EXISTS - the concrete incident, not a style preference.
# The live deploy script on the Contabo host ended with:
#
#   curl -s http://127.0.0.1:8085/health | grep -q "healthy" \
#     && echo "Deployment SUCCESS" || echo "WARNING: not ready yet."
#
# `A && B || C` is not if-then-else. The status of the list is the status of
# the LAST command run, so when the health check failed, `echo WARNING` ran,
# succeeded, and the script exited 0. Proven on that host: it printed WARNING
# and returned rc=0. An unhealthy deploy reported success, the webhook answered
# HTTP 200, and CI went green. That is SC2015, and catching it is the whole
# point of this stage.
#
# `set -e` does not save you: a command whose failure is consumed by && or ||
# is exempt from errexit. ShellCheck even suppresses SC2015 once `set -e`
# appears in the file, which is why nothing here relies on it.
#
# THE SEVERITY POLICY - two passes, and the second one is deliberately narrow.
#   1. -S warning                     fail on error and warning level.
#   2. -S info --include=SC2015,...   fail on exactly three info-level codes.
# The two numbers are SC_SEVERITY and SC_INFO_CODES, defined once above stage
# 2b; both stages read them, so neither can be widened without the other.
# SC2015 is the bug above; SC2164 (`cd` without `|| exit`) and SC2103 are the
# same shape - a step that silently carries on in the wrong state.
#
# Failing on EVERY info-level finding across seven repositories' worth of shell
# is how you get `--no-verify` inside a week, and then the gate protects
# nothing - exactly the history this file's header recounts. A narrow, boring,
# always-green policy that fires on the three codes that have actually shipped
# a broken deploy is worth more than a thorough one that gets bypassed.
#
# The policy's two passes, over one group of files, appending to one log. The
# groups are what this push changed and what it did not; running shellcheck
# twice over two lists is cheaper and exact, where filtering one combined log
# would mean parsing paths back out of "file:line:col: note".
sc_two_pass() {
  local out=$1; shift
  local rc=0
  shellcheck -S "$SC_SEVERITY" "$@" >>"$out" 2>&1 || rc=1
  shellcheck -S info --include="$SC_INFO_CODES" "$@" >>"$out" 2>&1 || rc=1
  return "$rc"
}
say "shellcheck"
if [ ${#SHF[@]} -eq 0 ]; then
  ok "no shell scripts"
elif ! have shellcheck; then
  # PATH already has .preflight-venv/bin prepended above, so the pip-installed
  # ShellCheck binary from the shellcheck-py wheel is found with nothing extra.
  skip "shellcheck not installed (run scripts/install-hooks.sh)"
else
  SH_MINE=(); SH_PRE=()
  for f in "${SHF[@]}"; do
    if changed "$f"; then SH_MINE+=("$f"); else SH_PRE+=("$f"); fi
  done
  SC_CLEAN=1
  : >"$WORK/shellcheck.err"; : >"$WORK/shellcheck.warn"
  if [ ${#SH_MINE[@]} -gt 0 ] && ! sc_two_pass "$WORK/shellcheck.err" "${SH_MINE[@]}"; then
    bad "shellcheck${SCOPE_NOTE}"; detail "$WORK/shellcheck.err" 40; SC_CLEAN=0
  fi
  if [ ${#SH_PRE[@]} -gt 0 ] && ! sc_two_pass "$WORK/shellcheck.warn" "${SH_PRE[@]}"; then
    warn "shellcheck: pre-existing, in script(s) this push did not change"
    detail "$WORK/shellcheck.warn" 20; SC_CLEAN=0
  fi
  if [ "$SC_CLEAN" -eq 1 ]; then
    ok "${#SHF[@]} script(s) clean (error+${SC_SEVERITY}, plus ${SC_INFO_CODES//,//})${SCOPE_NOTE}"
  fi
fi

# ------------------------------------------------ 2d. swallowed exit status --
# The gap SC2015 leaves open, and the reason this stage is not redundant.
#
# SC2015 is documented as "A && B || C is not if-then-else", which sounds like
# it covers the Contabo deploy line in stage 2c. It does not, and this was
# verified against shellcheck 0.11.0 rather than assumed:
#
#   grep -q x f && echo A || cp c d      SC2015 FIRES
#   grep -q x f && echo A || echo B      SC2015 IS SILENT
#   grep -q x f && rm -rf / || echo B    SC2015 IS SILENT
#
# Upstream's `checkShorthandIf` keys off the `||` branch only, and exempts it
# when it is echo/printf/exit/return or an assignment - things that cannot
# realistically fail. That is coherent for the defect SC2015 names ("C may run
# when A is true", a side-effect problem), but the Contabo incident was a
# different defect wearing the same syntax: the DISCARDED EXIT STATUS. Both
# branches were echoes, so the list always ended in a success, the script
# exited 0, the webhook answered HTTP 200 and CI went green on a dead service.
# SC2015 is structurally incapable of reporting that line.
#
# ShellCheck does have a rule that catches it - SC2312, under
# `-o check-extra-masked-returns`. It is not used: on this repository's five
# scripts alone it produces eight findings, none of them defects. Enabling it
# across seven repositories is the "fail on everything" policy stage 2c refuses
# to adopt, and it would buy `--no-verify` within the week.
#
# So the rule here is deliberately one shape wide: `A && B || C` where NEITHER
# B nor C can fail. That construct cannot report anything but success, which
# means A's status has been thrown away. Nothing else is flagged. It is checked
# in the repository's own scripts and in workflow `run:` blocks, since the
# deploy line that caused this lives in exactly such a block.
say "swallowed exit status"
: >"$WORK/swallow.warn"
SWALLOW_RC=0
PYTHONPATH="$WORK" PREFLIGHT_SH_LIST="$WORK/sh-files" \
   PREFLIGHT_WARN_OUT="$WORK/swallow.warn" \
   "$PY" - <<'PY' 2>"$WORK/swallow.err" || SWALLOW_RC=1
import os, re, sys
import pfwalk                                    # the shared walk, emitted above

# B and C both drawn from commands that do not fail => the && || list always
# succeeds and the status of A is gone.
INFALLIBLE = r"(?:echo|printf|true)\b"
SWALLOW = re.compile(r"&&\s*" + INFALLIBLE + r"[^|]*\|\|\s*" + INFALLIBLE)


def logical_lines(text):
    """Fold backslash continuations, keeping the first physical line number."""
    buf, start = "", None
    for n, raw in enumerate(text.split("\n"), 1):
        if start is None:
            start = n
        if raw.endswith("\\"):
            buf += raw[:-1] + " "
            continue
        yield start, buf + raw
        buf, start = "", None
    if start is not None:
        yield start, buf


def hits(text):
    for n, line in logical_lines(text):
        if line.lstrip().startswith("#"):      # a comment, including this file's
            continue
        if SWALLOW.search(line):
            yield n, line.strip()


SCOPE = pfwalk.changed_paths()      # None => scope unknown => everything is ours
WARN = open(os.environ["PREFLIGHT_WARN_OUT"], "w")
bad = 0


def report(path, where, found):
    """A finding in a file this push did not touch is written, not enforced."""
    global bad
    mine = SCOPE is None or path in SCOPE
    out = sys.stderr if mine else WARN
    for n, line in found:
        print(f"{where}:{n}: {line[:160]}", file=out)
        if mine:
            bad = 1


# The repository's own scripts - the same list stage 2c shellchecks - and the
# workflow run: blocks, where the deploy line that caused this stage lived.
# Both come from pfwalk, so 2b and 2d cannot end up inspecting different sets.
for path, where, source in list(pfwalk.shell_scripts()) + list(pfwalk.workflow_runs()):
    report(path, where, hits(source))

WARN.close()
sys.exit(bad)
PY
if [ -s "$WORK/swallow.warn" ]; then
  warn "swallowed exit status: pre-existing, in file(s) this push did not change"
  detail "$WORK/swallow.warn" 20
fi
if [ "$SWALLOW_RC" -eq 1 ]; then
  bad "the exit status of A is discarded by 'A && B || C' (both branches always succeed)${SCOPE_NOTE}"
  detail "$WORK/swallow.err" 20
  echo "       This reports success even when A failed. Use if/then/else:"
  echo "         if A; then echo ok; else echo WARNING; exit 1; fi"
elif [ ! -s "$WORK/swallow.warn" ]; then
  ok "no A && B || C discards the status of A${SCOPE_NOTE}"
fi

# --------------------------------------------- 2e. two-file awk, empty first file --
# `awk 'NR==FNR {...} ...' first second` is the idiom for "load the first file,
# then read the second". With an EMPTY first file NR==FNR stays true for the
# second file too, so its every line is swallowed as if it were the first. The
# merge guard in _auto-merge.yml did exactly that: /tmp/checks-reported.txt was
# empty, PENDING came out empty and the guard merged past checks still running.
# The fix is `FILENAME == ARGV[1]`; this stage keeps the old form from coming
# back. The pattern is spelled with a bracket class so this file does not match
# itself. Full-line comments are skipped - they may name the pitfall. Scope
# follows the rest of the gate: a hit in a file this push changed fails, a hit
# in a file it did not change is written as a warning, because this file is
# distributed to repositories whose own awk may be legitimate for non-empty input.
say "two-file awk on an empty first file"
: >"$WORK/nrfnr.hit"; : >"$WORK/nrfnr.warn"
for d in .github/workflows scripts; do
  [ -d "$d" ] || continue
  while IFS= read -r f; do
    grep -nE 'NR[[:space:]]*==[[:space:]]*FNR' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | sed "s|^|$f:|" >"$WORK/nrfnr.one" || true
    [ -s "$WORK/nrfnr.one" ] || continue
    if changed "$f"; then cat "$WORK/nrfnr.one" >>"$WORK/nrfnr.hit"
    else cat "$WORK/nrfnr.one" >>"$WORK/nrfnr.warn"; fi
  done < <(find "$d" -type f -print 2>/dev/null)
done
if [ -s "$WORK/nrfnr.warn" ]; then
  warn "two-file awk idiom: pre-existing, in file(s) this push did not change"
  detail "$WORK/nrfnr.warn" 20
fi
if [ -s "$WORK/nrfnr.hit" ]; then
  bad "two-file awk keyed on NR-equals-FNR - an empty first file makes it swallow the second${SCOPE_NOTE}"
  detail "$WORK/nrfnr.hit" 20
  echo "       Use FILENAME == ARGV[1] instead (see the guard in _auto-merge.yml)."
elif [ ! -s "$WORK/nrfnr.warn" ]; then
  ok "no awk two-file read relies on the first file being non-empty${SCOPE_NOTE}"
fi

# ------------------------------------------------------- 3. migration names --
# Measure the convention, then hold only NEW files to it.
say "migration naming"
MIGDIR=""
for d in supabase/migrations migrations db/migrations alembic/versions; do
  [ -d "$d" ] && { MIGDIR="$d"; break; }
done
if [ -z "$MIGDIR" ]; then
  ok "no migrations directory"
else
  mapfile -t MIGS < <(find "$MIGDIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.py' \) 2>/dev/null | sort)
  TOTAL=${#MIGS[@]}
  if [ "$TOTAL" -lt 3 ]; then
    ok "$MIGDIR: $TOTAL file(s) - too few to infer a convention"
  else
    N_TS=$(printf '%s\n' "${MIGS[@]}" | grep -cE "/[0-9]{14}_" || true)
    # The two patterns are disjoint - /[0-9]{3,6}_ needs the underscore right
    # after 3-6 digits, so a 14-digit name can never match it. Subtracting one
    # count from the other only ever undercounts the sequential names and hides
    # a convention the repository plainly has.
    N_SEQ=$(printf '%s\n' "${MIGS[@]}" | grep -cE "/[0-9]{3,6}_" || true)
    if   [ "$N_TS"  -gt $(( TOTAL / 2 )) ]; then PAT="[0-9]{14}_";   DESC="14-digit UTC timestamp"
    elif [ "$N_SEQ" -gt $(( TOTAL / 2 )) ]; then PAT="[0-9]{3,6}_";  DESC="zero-padded sequence"
    else PAT=""; fi
    if [ -z "$PAT" ]; then
      ok "$MIGDIR: no dominant convention among $TOTAL files - nothing to enforce"
    else
      if [ -z "$BASE" ]; then
        skip "migration naming: no merge-base with origin (shallow clone?) - cannot tell new from existing"
      else
        NEWBAD=$(git diff --name-only --diff-filter=A "$BASE" HEAD -- "$MIGDIR" 2>/dev/null \
                 | grep -E "\.(sql|py)$" | grep -vE "/${PAT}" || true)
        if [ -n "$NEWBAD" ]; then
          bad "$MIGDIR uses the $DESC convention; these new files do not:"
          printf '       %s\n' $NEWBAD
        else
          ok "$MIGDIR: new files match the $DESC convention"
        fi
      fi
    fi
  fi
fi

# ------------------------------------------------------- 4. import contracts --
say "import boundaries"
if ! grep -qs importlinter pyproject.toml setup.cfg .importlinter 2>/dev/null; then
  ok "no import contracts declared"
elif ! have lint-imports; then
  skip "lint-imports not installed (declared in pyproject but absent here)"
elif lint-imports >"$WORK/imports" 2>&1; then
  ok "contracts hold"
else
  bad "import contracts violated"; detail_last "$WORK/imports" 20
fi

# ------------------------------------------- what the repository's CI runs --
# Parsed once; stage 5 and stage 6c both read it. One line per command:
#   meta<TAB>workflows=<n> preflight=<0|1>
#   test<TAB><shell-quoted argv>      a pytest invocation a workflow runs
#   check<TAB><shell-quoted argv>     ruff / mypy / black / ... / scripts/*verify*.py
# Only single-line `run:` steps. Leading NAME=value assignments are kept (CI's
# `PYTHONPATH=src python -m pytest`); `poetry|uv|pipenv run` is stripped - the
# venv on PATH is that environment. Anything with a shell metacharacter, every
# install, deploy and multi-line block is never replayed.
WF_CMDS="$WORK/wf-cmds"
"$PY" - .github/workflows >"$WF_CMDS" 2>/dev/null <<'PYEOF'
import glob, os, re, shlex, sys
TOOLS = {"ruff", "mypy", "black", "isort", "flake8", "pyright", "pylint", "bandit", "vulture"}
SCRIPT = re.compile(r"^(scripts|tools|ci)/[\w./-]*(verify|check|lint|validate)[\w.-]*\.py$")
files = sorted(glob.glob(os.path.join(sys.argv[1], "*.y*ml")))
uses_preflight = 0
out = []
for wf in files:
    text = open(wf, encoding="utf-8", errors="replace").read()
    if "_preflight.yml" in text:
        uses_preflight = 1
    if "working-directory" in text or not re.search(r"\b(push|pull_request)\b", text):
        continue
    for m in re.finditer(r"^\s*(?:-\s+)?run:\s*(?![|>])(.+?)\s*$", text, re.M):
        raw = m.group(1).strip().strip("'\"")
        if any(c in raw for c in ("&&", "||", ";", "|", "$", "`", ">", "<")):
            continue
        try:
            argv = shlex.split(raw)
        except ValueError:
            continue
        env = []
        while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
            env.append(argv.pop(0))
        if argv[:2] in (["poetry", "run"], ["uv", "run"], ["pipenv", "run"]):
            argv = argv[2:]
        if not argv:
            continue
        mod = argv[2] if argv[0] in ("python", "python3") and argv[1:2] == ["-m"] and len(argv) > 2 else None
        tool = mod or argv[0]
        if tool == "pytest":
            kind = "test"
        elif tool in TOOLS or (argv[0] in ("python", "python3") and len(argv) > 1 and SCRIPT.match(argv[1])):
            kind = "check"
        else:
            continue
        line = "%s\t%s" % (kind, shlex.join(env + argv))
        if line not in out:
            out.append(line)
print("meta\tworkflows=%d preflight=%d" % (len(files), uses_preflight))
print("\n".join(out))
PYEOF
WF_N=$(sed -n 's/^meta\tworkflows=\([0-9]*\).*/\1/p' "$WF_CMDS"); WF_N=${WF_N:-0}
WF_PF=$(sed -n 's/^meta\t.*preflight=\([01]\).*/\1/p' "$WF_CMDS"); WF_PF=${WF_PF:-0}

# Replay one parsed command. A leading NAME=value that is a path list gets the
# caller's value appended, so the global gate's worktree-first PYTHONPATH
# survives a workflow's `PYTHONPATH=src`. A tool that is not installed is a
# named skip, never a red: the gate must not fail on the machine's state.
replay_wf() {
  local cmd="$1" label="$2" a tool i=0
  local -a argv env
  eval "argv=($cmd)"
  while [ "$i" -lt "${#argv[@]}" ] && [[ "${argv[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    a="${argv[$i]}"
    if [ "${a%%=*}" = PYTHONPATH ] && [ -n "${PYTHONPATH:-}" ]; then a="$a:$PYTHONPATH"; fi
    env+=("$a"); i=$((i+1))
  done
  argv=("${argv[@]:$i}")
  tool="${argv[0]}"
  if ! have "$tool"; then
    skip "$label \`$cmd\`: $tool not installed (install-deps.sh installs dependency groups)"
    return 0
  fi
  if env ${env[@]+"${env[@]}"} "${argv[@]}" >"$WORK/replay.out" 2>&1; then
    ok "$label \`$cmd\`"; detail_last "$WORK/replay.out" 1
  else
    bad "$label \`$cmd\` - CI runs this exact command on this tree"
    detail_last "$WORK/replay.out" 20
  fi
}

# -------------------------------------------------------------------- 5. tests --
say "tests"
# WHICH pytest. The gate's verdict must be CI's verdict, so it runs the tests
# CI runs. A repository whose CI is _preflight.yml, or that has no workflow at
# all, gets the default run below (that IS what its CI runs, or will once sync
# installs integrate.yml). A repository with its own workflow gets that
# workflow's pytest commands replayed verbatim - and if it runs none, there is
# nothing for a test failure to turn red. Found on 2026-10-13: a Node repo whose
# CI is `npm test` was refused for a Python suite its CI never runs, and a repo
# whose CI runs `PYTHONPATH=src pytest tests/` was judged by a different
# invocation. .preflight.conf's PREFLIGHT_PYTEST_ARGS keeps the default run.
if [ "${PREFLIGHT_SKIP_TESTS:-0}" = "1" ]; then
  skip "tests: PREFLIGHT_SKIP_TESTS=1"
elif [ "$WF_N" -gt 0 ] && [ "$WF_PF" = 0 ] && [ -z "$PREFLIGHT_PYTEST_ARGS" ]; then
  if grep -q '^test' "$WF_CMDS"; then
    while IFS=$'\t' read -r _ CMD; do
      replay_wf "$CMD" "tests (as CI runs them)"
    done < <(grep '^test' "$WF_CMDS")
  else
    ok "tests: the repository's CI runs no pytest - nothing for a test to turn red"
  fi
elif [ ! -d tests ] && ! compgen -G "test_*.py" >/dev/null 2>&1; then
  ok "no test suite"
elif ! pymod pytest; then
  skip "tests: pytest not installed (run scripts/install-hooks.sh)"
else
  # Collect first. A collection error that is purely ModuleNotFoundError is
  # classified below: a module this repository DECLARES is missing because the
  # machine lacks it (environment, skip); a module declared nowhere is missing
  # because it was never written (the author's defect, fail).
  if "$PY" -m pytest --collect-only -q $PREFLIGHT_PYTEST_ARGS >"$WORK/collect" 2>&1; then
    TO=""; pymod pytest_timeout && TO="--timeout=120"
    [ -n "$PREFLIGHT_PYTEST_ARGS" ] && echo "       (.preflight.conf: $PREFLIGHT_PYTEST_ARGS)"
    if "$PY" -m pytest -q $TO $PREFLIGHT_PYTEST_ARGS >"$WORK/tests" 2>&1; then
      ok "$(tail -1 "$WORK/tests" | tr -d '\n')"
    else
      RC=$?
      # Exit 5 is "no tests ran" - an empty suite, not a failing one. Owner
      # decision A (2026-10-20): advisory, not red, when the push edits no
      # test file; red when it does (a push that edits tests must leave a
      # suite that collects something).
      if [ "$RC" -eq 5 ] && ! tests_touched; then
        echo "       ADVISORY: no collectable tests in tree - suite gate skipped"
        ok "tests: the suite collects 0 tests and this push touches no test file (advisory)"
      else
        bad "pytest"; detail_last "$WORK/tests" 25
      fi
    fi
  elif grep -q "ModuleNotFoundError" "$WORK/collect"; then
    # ModuleNotFoundError has two meanings and pytest prints the same line for
    # both. The repository's own declarations are what tell them apart:
    #   DECLARED as a dependency -> this machine has not installed it. An
    #       environment fact, the author changed nothing, CI installs it. SKIP.
    #   DECLARED NOWHERE         -> nothing would ever install it, so the test
    #       imports code that is meant to be in the tree and is not: the
    #       abandoned half-edit (test written, implementation never was). That
    #       IS what the author changed, so it FAILS, naming the modules.
    MODS=$(grep -oE "No module named '[^']+'" "$WORK/collect" | sort -u | sed "s/No module named //" | tr '\n' ' ')
    MODNAMES=$(grep -oE "No module named '[^']+'" "$WORK/collect" \
               | sed -E "s/^No module named '(.+)'$/\1/" | sort -u | tr '\n' ' ')
    "$PY" - "$ROOT" $MODNAMES >"$WORK/undeclared" 2>"$WORK/deps.err" <<'PY'
import pathlib, re, sys

# Distribution names and import names differ. Normalising separators and case
# covers ruamel.yaml / ruamel_yaml; it does NOT cover a package whose import
# name is a different word (Pillow / PIL, zxing-cpp / zxingcpp). Those need the
# explicit table below - without it the gate reported declared dependencies as
# "not in the tree" and failed every push of a repo that uses Pillow.
def norm(name):
    return re.sub(r"[-_.]+", "_", name).strip().lower()

IMPORT_TO_DIST = {
    "pil": "pillow", "zxingcpp": "zxing_cpp", "yaml": "pyyaml",
    "docx": "python_docx", "pptx": "python_pptx", "bs4": "beautifulsoup4",
    "cv2": "opencv_python", "sklearn": "scikit_learn", "dateutil": "python_dateutil",
    "dotenv": "python_dotenv", "jwt": "pyjwt", "fitz": "pymupdf",
    "magic": "python_magic", "multipart": "python_multipart", "attr": "attrs",
    "psycopg2": "psycopg2_binary", "msgpack": "msgpack_python",
}
# The same table read the other way: distribution -> the module names it provides.
DIST_TO_IMPORTS = {}
for _imp, _dist in IMPORT_TO_DIST.items():
    DIST_TO_IMPORTS.setdefault(_dist, set()).add(_imp)

root = pathlib.Path(sys.argv[1])
declared = set()   # every name a manifest mentions - generous on purpose
required = set()   # names that are really dependencies - the strict subset

for req in root.rglob("requirements*.txt"):
    if {".git", ".venv", ".preflight-venv"} & set(req.parts):
        continue
    for line in req.read_text(errors="ignore").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        name = norm(re.split(r"[<>=!~\[; ]", line, maxsplit=1)[0])
        declared.add(name)
        required.add(name)

pyproject = root / "pyproject.toml"
if pyproject.is_file():
    # A regex and deliberately NOT tomllib: tomllib is 3.11+, and this stage
    # must not fail on the state of the interpreter it happens to run on.
    # Matches a quoted requirement with or without a version specifier; being
    # generous here can only turn a fail into a skip, never the reverse.
    pyproject_names = set()
    for m in re.finditer(r"""["']([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:["']|[<>=!~;,\[])""",
                         pyproject.read_text(errors="ignore")):
        pyproject_names.add(norm(m.group(1)))
    declared |= pyproject_names
    # The regex also matches `license = "MIT"` and the project's own name, which
    # are not dependencies and are never installed. Counted as dependencies they
    # would make every pyproject repository "uncertain" and the FAIL below
    # unreachable. With a toml parser, read the dependency tables for real;
    # without one, fall back to the generous set (more skips, never a false FAIL).
    try:
        try:
            import tomllib
        except ModuleNotFoundError:
            import tomli as tomllib
        doc = tomllib.loads(pyproject.read_text(errors="ignore"))
        proj = doc.get("project") or {}
        poetry = (doc.get("tool") or {}).get("poetry") or {}
        entries = list(proj.get("dependencies") or [])
        for items in (proj.get("optional-dependencies") or {}).values():
            entries += items
        for items in (doc.get("dependency-groups") or {}).values():
            entries += [i for i in items if isinstance(i, str)]
        tables = [poetry.get("dependencies") or {}, poetry.get("dev-dependencies") or {}]
        tables += [(g or {}).get("dependencies") or {} for g in (poetry.get("group") or {}).values()]
        entries += [n for t in tables for n in t if n.lower() != "python"]
        for entry in entries:
            required.add(norm(re.split(r"[<>=!~\[; ]", entry.strip(), maxsplit=1)[0]))
    except Exception:
        required |= pyproject_names

# Which distributions are installed here, and which modules they provide. This
# is what lets the gate answer "does a declared distribution provide this
# module" from the metadata instead of from a table of renames: psycopg2-binary
# provides psycopg2, Pillow provides PIL, and the next rename nobody has listed
# is answered by the installed package itself. packages_distributions() is 3.10+;
# on an older interpreter only the static table above is available.
installed = {}
provided_by = {}
try:
    from importlib import metadata as md
    for dist in md.distributions():
        dist_name = dist.metadata["Name"]
        if dist_name:
            installed[norm(dist_name)] = dist
    for imp, dists in getattr(md, "packages_distributions", lambda: {})().items():
        for dn in dists:
            provided_by.setdefault(norm(dn), set()).add(norm(imp))
except Exception as exc:
    print(f"installed-package metadata unreadable: {exc}", file=sys.stderr)

def provides(dist_name):
    return {dist_name} | provided_by.get(dist_name, set()) | DIST_TO_IMPORTS.get(dist_name, set())

# A module is also declared when a declared distribution DEPENDS on it (starlette
# via fastapi) - one level, from the installed distribution's Requires-Dist.
# A declared distribution that is not installed here cannot be asked what it
# depends on, so it is reported as uncertain instead of being assumed to have
# nothing: the module may be one of its dependencies.
via_declared = set()
uncertain = []
for dist_name in sorted(required):
    via_declared |= provides(dist_name)
    dist = installed.get(dist_name)
    if dist is None:
        uncertain.append(dist_name)
        continue
    try:
        requires = dist.requires or []
    except Exception as exc:
        uncertain.append(f"{dist_name} (metadata unreadable: {exc})")
        continue
    for line in requires:
        m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        if m:
            via_declared |= provides(norm(m.group(1)))

# Only the top-level module can be declared: ubo.rights is ubo's to provide.
def is_declared(mod):
    top = norm(mod.split(".", 1)[0])
    return top in declared or IMPORT_TO_DIST.get(top) in declared or top in via_declared

undeclared = sorted({m for m in sys.argv[2:] if not is_declared(m)})
for mod in undeclared:
    print(mod)
if not undeclared:
    sys.exit(0)
# Declared nowhere - but only the author's defect if nothing uninstalled could
# still be providing it. A false FAIL blocks a push; a false skip only delays
# the signal to CI, which installs everything and decides.
if uncertain:
    print("cannot rule out: " + ", ".join(uncertain), file=sys.stderr)
    sys.exit(2)
sys.exit(1)
PY
    DECL_RC=$?
    if [ "$DECL_RC" -eq 0 ]; then
      skip "tests: dependencies missing here ($MODS) - run scripts/install-hooks.sh; CI runs them"
    elif [ "$DECL_RC" -eq 2 ]; then
      skip "tests: dependencies missing here ($MODS); not named by any manifest: $(tr '\n' ' ' <"$WORK/undeclared" | sed 's/ *$//'); declared but not installed here: $(sed -n 's/^cannot rule out: //p' "$WORK/deps.err" | head -1) - cannot rule out that the module is a dependency of one of them; run scripts/install-hooks.sh, CI installs them and decides"
    elif [ "$DECL_RC" -eq 1 ] && [ -s "$WORK/undeclared" ]; then
      MISSING=$(tr '\n' ' ' <"$WORK/undeclared" | sed 's/ *$//')
      bad "tests: the suite imports modules that are not in the tree: $MISSING"
      echo "       No requirements*.txt and no pyproject.toml declares them, so no"
      echo "       install would ever provide them - this is not a missing dependency."
      echo "       A test imports code that does not exist here (an unfinished change"
      echo "       that added the test but never added the module). Add it, or remove"
      echo "       the test that imports it."
      grep -E "ModuleNotFoundError" "$WORK/collect" | sort -u | head -10 | sed 's/^/       /'
    else
      skip "tests: dependencies missing here ($MODS); could not read this repository's declarations to check them - $(head -1 "$WORK/deps.err")"
    fi
  else
    # A collect failure is a red only when the push touches the suite (owner
    # decision A, 2026-10-20). Otherwise the repository's suite is not
    # collectable and this push changed nothing about it - an environment or
    # pre-existing state fact, so a loud advisory line and a pass. Never a
    # bare `except: pass`: the ADVISORY line must be in the log.
    if tests_touched; then
      bad "pytest cannot collect the suite"; detail_last "$WORK/collect" 20
    else
      echo "       ADVISORY: no collectable tests in tree - suite gate skipped"
      ok "tests: pytest cannot collect the suite and this push touches no test file (advisory)"
      detail_last "$WORK/collect" 5
    fi
  fi
fi

# ------------------------------------------------- 6. shared narrative files --
# Two parallel sessions editing one index file is a guaranteed merge conflict.
say "shared narrative files"
SHARED_HIT=""
if [ -n "$BASE" ]; then
  for f in docs/plans/active-plan.md docs/journal.md; do
    [ -f "$f" ] || continue
    if git diff --name-only "$BASE" HEAD -- "$f" 2>/dev/null | grep -q .; then
      # Rewriting an existing block is what turns a clean union merge into a
      # duplicate. Appending is safe, so only a net deletion is reported.
      DEL=$(git diff --numstat "$BASE" HEAD -- "$f" 2>/dev/null | awk '{print $2}')
      [ "${DEL:-0}" -gt 0 ] && SHARED_HIT="${SHARED_HIT} $f(-$DEL)"
    fi
  done
fi
if [ -z "$BASE" ]; then
  skip "shared files: no merge-base with origin"
elif [ -n "$SHARED_HIT" ]; then
  bad "lines removed from a shared index:${SHARED_HIT}"
  echo "       These files are merge=union. Append your block; never rewrite one"
  echo "       another line already wrote. The plan itself goes in its own file."
else
  ok "no shared index was rewritten"
fi

# ------------------------------------------------- 6b. workflow manifests --
# A workflow that runs `poetry install` in a tree with no pyproject.toml fails
# on GitHub in the first 20 seconds, every time, and no local test notices: the
# workflow is not code anything imports. Bud-Fox/msk-capintel shipped exactly
# that and went red on its first five pushes (2026-10-12), because the workflow
# was committed one task before the package it installs. So: every package-
# manager command a workflow's `run:` invokes must find its manifest in the
# pushed tree. A workflow that sets `working-directory` is skipped by name -
# resolving it per step needs a YAML model this file deliberately does not own.
say "workflow manifests"
WFM_FOUND=0; WFM_BAD=0
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  WFM_FOUND=1
  if grep -q 'working-directory' "$wf"; then
    skip "workflow manifests: $wf sets working-directory"; continue
  fi
  MISSING=$("$PY" - "$wf" <<'PYEOF'
import os, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
need = []
rules = [
    (r"\bpoetry\s+(install|run|build|lock|check)\b", ["pyproject.toml"]),
    (r"\buv\s+(sync|run)\b", ["pyproject.toml"]),
    (r"\bnpm\s+ci\b", ["package.json", "package-lock.json"]),
    (r"\b(npm|yarn|pnpm)\s+(install|test|run)\b", ["package.json"]),
    (r"\bcargo\s+(build|test|check)\b", ["Cargo.toml"]),
    (r"\bgo\s+(build|test|vet)\b", ["go.mod"]),
]
for pat, files in rules:
    if re.search(pat, text):
        need += [f for f in files if not os.path.exists(f)]
for m in re.finditer(r"pip3?\s+install\b[^\n]*?\s-r\s+([^\s'\"]+)", text):
    f = m.group(1)
    if "$" not in f and not os.path.exists(f):
        need.append(f)
print(" ".join(sorted(set(need))))
PYEOF
)
  if [ -n "$MISSING" ]; then
    WFM_BAD=1
    if changed "$wf"; then
      bad "$wf runs a package manager whose manifest is absent: $MISSING"
      echo "       Commit the manifest in the same push as the workflow, or guard"
      echo "       the step with  if: hashFiles('<manifest>') != ''"
    else
      warn "$wf needs absent manifest(s): $MISSING"
    fi
  fi
done
[ "$WFM_FOUND" -eq 1 ] || ok "no workflows"
[ "$WFM_FOUND" -eq 1 ] && [ "$WFM_BAD" -eq 0 ] && ok "every workflow's manifests are present"

# --------------------------------------------- 6c. the workflow's own checks --
# A repository's CI is whatever its workflow runs, not what this file guesses.
# msk-capintel's offline.yml runs ruff, mypy and a docs verifier besides
# pytest; 4ca33b4 pushed a cli.py importing a module that was not committed yet,
# mypy failed it on GitHub, and a gate running only pytest let it through. So
# the single-line `run:` steps that are CHECKS are replayed here, in the venv,
# on the pushed tree: same command, same tree, same verdict. The list is built
# once, before stage 5, by wf_commands below.
say "workflow checks"
if ! grep -q '^check' "$WF_CMDS"; then
  ok "no replayable check steps in the workflows"
else
  while IFS=$'\t' read -r _ CMD; do
    replay_wf "$CMD" "workflow check"
  done < <(grep '^check' "$WF_CMDS")
fi

# --------------------------------------------------------------- 7. summary --
echo
if [ -n "$SKIPPED" ]; then
  printf '%sskipped%s:%b\n\n' "$Y" "$N" "$SKIPPED"
fi
if [ -n "$WARNED" ]; then
  printf '%swarned%s (real findings, in files this push did not change):%b\n\n' "$Y" "$N" "$WARNED"
fi
if [ $FAIL -eq 0 ]; then
  printf '%sPREFLIGHT PASS%s\n' "$G" "$N"; exit 0
else
  printf '%sPREFLIGHT FAIL%s - fix before pushing\n' "$R" "$N"; exit 1
fi
