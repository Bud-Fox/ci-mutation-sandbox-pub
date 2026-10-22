#!/usr/bin/env bash
#
# PreToolUse(Bash): refuse the blind-staging spellings of git.
#
#   git add -A | --all | -u | --update | .        blind staging
#   git commit -a | --all | -am                   stages every tracked change
#   git commit --no-verify | -n                   skips .githooks/pre-commit
#   git push --no-verify                          skips .githooks/pre-push
#
# The last one has an escape, CLAUDE_PUSH_UNVERIFIED=1; the three above it do
# not. See THE PUSH ESCAPE below for why the asymmetry is the correct one.
#
# WHY, WITH THE CONCRETE INCIDENT
# A subagent crashed mid-edit and left half a file rewritten. Another had
# deliberately corrupted a source file to prove a falsification experiment and
# had not restored it. `git add -A` swept both onto main under the owner's
# name, _auto-merge merged it, and the deploy webhook shipped it. Nothing in
# the pipeline is wrong there - every stage did exactly what it was told. The
# defect is the staging verb.
#
# WHAT THIS IS AND IS NOT
# This is a PROXY, not the enforcement. The invariant that matters is the
# STAGED SET at commit time, not the flag used to build it:
#   * `git add -A && git reset -- <foreign>` is a correct commit, and this hook
#     lets it through, because judging flags cannot judge a staged set.
#   * `sh -c 'git add -A'`, a shell alias, `eval`, and `bash scripts/sync.sh`
#     all walk past this hook - it only ever sees the top-level Bash string, so
#     any git command inside a script file is invisible to it.
# The load-bearing check is .githooks/pre-commit, which git runs no matter how
# the commit was invoked. That hook's one hole is `--no-verify`, and closing
# that hole is this hook's most important job.
#
# WHY PreToolUse AND NOT permissions.deny ALONE
# PreToolUse fires before any permission-mode check, so a "deny" decision
# blocks the tool even under bypassPermissions and
# --dangerously-skip-permissions. It also RUNS in the sessions these settings
# are synced into: most are `claude -p`, the SDK or a cloud container, which
# show no trust dialog at all, and hooks in a settings file are listed Used in
# exactly that case - where permissions.allow and additionalDirectories are
# listed not used, with a `this workspace has not been trusted` warning.
#   https://code.claude.com/docs/en/permissions#what-runs-before-you-trust-a-folder
#   https://code.claude.com/docs/en/security#additional-safeguards
# permissions.deny is NOT weakened by either of those - deny rules apply in an
# untrusted folder and block in every mode including bypassPermissions
# (https://code.claude.com/docs/en/permission-modes#available-modes). It is not
# the gate because it matches a command PREFIX and cannot read one: `git add
# -v -A` moves the flag past it, and it carries no --no-verify entry at all,
# which is the one hole in .githooks/pre-commit and this hook's most important
# job. Defence in depth for the spellings it names, never the gate.
#
# THE PUSH ESCAPE, AND WHY PUSH HAS ONE WHEN COMMIT DOES NOT
#   CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify
# .githooks/pre-push has always documented `git push --no-verify` as the
# emergency exit, and this hook used to deny it with no exit at all. Shipped
# together that is not a strict gate, it is a promise the same change breaks:
# a pusher whose gate fails on something they cannot fix has no way to push,
# and the fix they reach for is deleting the hook. Measured, not feared - the
# gate was run against 47 repositories' heads and 17 failed on pre-existing
# code the pusher never wrote.
#
# The commit-side denials keep no escape because they have one already, one
# layer down: .githooks/pre-commit judges the staged set and takes
# CLAUDE_COMMIT_FOREIGN=1. Refusing to TYPE `git commit --no-verify` costs
# nothing, because the commit itself is still reachable on the record. Push has
# no second layer - --no-verify means git runs no hook at all - so a denial
# here is the whole road, not a detour off it.
#
# Nothing reads CLAUDE_PUSH_UNVERIFIED at push time; --no-verify guarantees
# there is no hook left to read it. Its only job is to be typed. An env prefix
# is one keystroke, appears verbatim in the transcript, and is therefore a
# decision on the record rather than a silent bypass - the same argument
# .githooks/pre-commit's header makes for CLAUDE_COMMIT_FOREIGN, which was
# simply never carried across to push.
#
# It is read from the command string, not from this process's environment: the
# Bash tool's shell is not this hook's parent, so an `export` in some earlier
# turn is invisible here and MUST NOT count - a bypass that survives out of
# sight of the command that uses it is the silent bypass the shape exists to
# prevent. It gates `git push --no-verify` in the one simple command it
# prefixes, and nothing else: not the segment after `&&`, not commit, not add.
#
# FALSE POSITIVES ARE THE ONLY WAY THIS DIES
# Deny one legitimate `git add <path>` and the hook is deleted inside a week -
# exactly the history scripts/preflight.sh's own header recounts about a gate
# that failed on the state of the machine rather than on the change. Every
# allow-case is pinned in .claude/hooks/selftest.sh. Add a deny, add its
# neighbouring allow.
#
set -uo pipefail

PAYLOAD="$(cat)"

# Fail OPEN when there is no interpreter. A hook that denies every Bash call
# because a binary is missing is the machine-state failure preflight.sh's
# header is about; it would be uninstalled the same day. The pre-commit hook
# still stands behind this, so an open failure here is not an open door.
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || exit 0

exec "$PY" - "$PAYLOAD" <<'PY'
import json
import os
import re
import shlex
import subprocess
import sys

HOOK = ".claude/hooks/deny-blind-staging.sh"

ALTERNATIVE = (
    "Stage an explicit pathspec instead: run `git status --porcelain`, decide "
    "which of those paths you actually changed, and name them - "
    "`git add src/thing.py docs/notes.md`. A named directory is an explicit "
    "pathspec too: `git add src/` is fine. This hook judges the verb, not the "
    "result, so `git add -A` followed by a corrective `git reset` is refused "
    "here as well: the corrective is only as good as the list you pass it, and "
    "nothing in a command string can verify that list. Name the paths."
)

WHY = (
    "Blind staging commits work this session did not author - a crashed "
    "subagent's half-edit, or a file corrupted on purpose for an experiment "
    "and never restored. On this repo that lands on main under the owner's "
    "name and auto-deploys."
)

# The push denial gets its own pair. Handing an agent the staging advice above
# after it tried to push is a reason it cannot act on, and a denial nobody can
# act on is how the hook file gets deleted instead of obeyed.
PUSH_ESCAPE = "CLAUDE_PUSH_UNVERIFIED"

PUSH_WHY = (
    "This repository auto-deploys main, so the pre-push run of "
    "scripts/preflight.sh is the last thing standing between a broken change "
    "and a live deploy."
)

PUSH_ALTERNATIVE = (
    "Read what preflight.sh actually reported and fix that. If it failed on "
    "code this change never touched, that is a bug in the gate, not in your "
    "change - report it. If the push has to happen anyway, say so on the "
    "record rather than silently: `%s=1 git push --no-verify`. That prefix is "
    "one keystroke and it stands in the transcript as a deliberate decision, "
    "which is the entire point of it." % PUSH_ESCAPE
)


def allow():
    sys.exit(0)


def deny(what, why, alternative=ALTERNATIVE):
    reason = "%s  %s  %s  (blocked by %s)" % (what, why, alternative, HOOK)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


try:
    data = json.loads(sys.argv[1])
except Exception:
    allow()

if data.get("tool_name") != "Bash":
    allow()

command = (data.get("tool_input") or {}).get("command") or ""
if not isinstance(command, str) or not command.strip():
    allow()

# cwd is the field to trust: ${CLAUDE_PROJECT_DIR} does not follow into a
# worktree, it stays at the directory the session started in. Inside a worktree
# only cwd names the tree the command will actually touch.
cwd = data.get("cwd") or os.getcwd()

# ------------------------------------------------------- split into commands --
# ONE character-by-character pass that tracks quote state and heredoc state at
# the same time. Both earlier attempts failed because they picked one:
#
#   1. Tokenise the whole string with shlex.  `<<'EOF' ... git add -A ... EOF`
#      is denied - an agent cannot write a script, a README, or this file.
#   2. Split on newlines first, then tokenise.  Heredocs behave, but a
#      multi-line quoted argument is cut into pieces and
#          git commit -m "fix
#          git add -A          <- allowed
#          done"
#      is denied. Every real commit message in this repository is multi-line,
#      so this blocked the commit of this very hook and forced `git commit -F`.
#
# Heredocs need line awareness; quoted arguments need the opposite. No ordering
# of two separate passes satisfies both, so there is one pass:
#
#   * a newline, `;`, `&&`, `||`, `|`, `&`, `(`, `)`, `<`, `>` separate simple
#     commands ONLY when every quote is closed;
#   * a heredoc operator records its delimiter, and at the next unquoted
#     newline the body is consumed as RAW LINES until the delimiter - never
#     scanned, so an apostrophe in the body cannot corrupt the quote state.
#
# What this means in practice: text that is an ARGUMENT is never read as a
# command. An agent can name the forbidden spellings in a commit message, a
# heredoc, an echo, or a comment. Only something in command position is judged.
HEREDOC_AT = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
SEPARATORS = set("&|;()<>\n")

# Words that can stand in front of the real command. Without these,
# `if git add -A; then ...` and `{ git add -A; }` present `if` and `{` as the
# first token and walk straight past the check.
PREFIX_WORDS = {"if", "then", "elif", "else", "do", "while", "until", "!",
                "{", "}", "time", "command", "builtin", "exec", "nohup",
                "sudo", "and", "or"}


def simple_commands(text):
    """Every simple command in `text`, as a list of argv token lists."""
    found = []
    buf = []
    pending = []          # heredoc delimiters queued on the current line
    in_single = False
    in_double = False
    i = 0
    n = len(text)

    def flush():
        piece = "".join(buf).strip()
        del buf[:]
        if not piece:
            return
        try:
            lexer = shlex.shlex(piece, posix=True, punctuation_chars=False)
            lexer.whitespace_split = True
            found.append(list(lexer))
        except ValueError:
            # Unbalanced quote in this piece only. Skip it; the pieces around
            # it are still checked.
            pass

    while i < n:
        c = text[i]

        if in_single:
            buf.append(c)
            if c == "'":
                in_single = False
            i += 1
            continue

        if in_double:
            # Inside double quotes a backslash still escapes, so \" does not
            # close the string.
            if c == "\\" and i + 1 < n:
                buf.append(c)
                buf.append(text[i + 1])
                i += 2
                continue
            buf.append(c)
            if c == '"':
                in_double = False
            i += 1
            continue

        # --- unquoted ---
        if c == "\\":
            # Escapes the next character, a newline included: that is a line
            # continuation and must NOT separate commands.
            if i + 1 < n:
                buf.append(c)
                buf.append(text[i + 1])
                i += 2
            else:
                i += 1
            continue

        if c == "'":
            in_single = True
            buf.append(c)
            i += 1
            continue

        if c == '"':
            in_double = True
            buf.append(c)
            i += 1
            continue

        if c == "<":
            m = HEREDOC_AT.match(text, i)
            if m:
                # `<<<word` is a here-string, not a heredoc: the regex cannot
                # match it because `<` is not a delimiter character.
                pending.append((m.group(3), m.group(1) == "-"))
                i = m.end()
                continue

        if c == "\n":
            i += 1
            # Bodies are consumed as raw lines. Scanning them would let an
            # apostrophe inside the body open a quote that never closes.
            for delim, dashed in pending:
                while i < n:
                    j = text.find("\n", i)
                    if j == -1:
                        line, i = text[i:], n
                    else:
                        line, i = text[i:j], j + 1
                    probe = line.lstrip("\t") if dashed else line
                    if probe.strip() == delim:
                        break
            del pending[:]
            flush()
            continue

        if c in SEPARATORS:
            flush()
            i += 1
            continue

        buf.append(c)
        i += 1

    flush()
    return found


segments = simple_commands(command)

# ------------------------------------------------------------ project tree --
# `git -C /tmp/whatever add -A` in a throwaway clone is legitimate - scripts/
# sync.sh does exactly that - so the check applies only when the command
# operates on a tree that overlaps this project.
_roots = None


def project_roots():
    global _roots
    if _roots is not None:
        return _roots
    found = set()
    for p in (cwd, os.environ.get("CLAUDE_PROJECT_DIR")):
        if p:
            try:
                found.add(os.path.realpath(p))
            except OSError:
                pass
    try:
        r = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            found.add(os.path.realpath(r.stdout.strip()))
    except Exception:
        pass
    _roots = found
    return _roots


def overlaps_project(tree):
    try:
        t = os.path.realpath(tree)
    except OSError:
        return True
    for r in project_roots():
        # Either direction: a tree inside the project, or a tree that CONTAINS
        # the project (`git -C / add -A` would sweep it just the same).
        if t == r or t.startswith(r + os.sep) or r.startswith(t + os.sep):
            return True
    return False


# --------------------------------------------------------------- git parse --
# Options that take a SEPARATE value, so the token after them is data and must
# never be read as a flag. Split per subcommand on purpose: the same letter
# means different things.
#
#   git -C <dir>        a directory - only BEFORE the subcommand
#   git commit -C <rev> reuse a commit message. Reading that as a directory
#                       would resolve to a path outside the repo and hand back
#                       a bogus "not this project, allow".
GIT_GLOBAL_VALUE = {"-c", "--namespace", "--exec-path", "--config-env",
                    "--super-prefix"}
GIT_GLOBAL_TREE = {"-C", "--git-dir", "--work-tree"}

ADD_VALUE = {"--chmod", "--pathspec-from-file", "--pathspec-file-nul"}
COMMIT_VALUE = {"-m", "--message", "-F", "--file", "-c", "--reedit-message",
                "-C", "--reuse-message", "-t", "--template", "--author",
                "--date", "--cleanup", "--fixup", "--squash", "--trailer",
                "--pathspec-from-file"}
# Short options that consume the next token when they end a combined cluster,
# e.g. `git commit -sm "msg"`.
COMMIT_VALUE_SHORT = set("mFcCt")

# Pathspecs that mean "the whole tree" however they are spelled.
WHOLE_TREE = {".", "./", "..", "../", ":/", ":", "*"}


def split_git(argv):
    """(subcommand, args, tree, assignments) for a git invocation, or None."""
    i = 0
    # Leading VAR=value assignments, and `env VAR=value git ...`. They are kept
    # rather than only skipped: CLAUDE_PUSH_UNVERIFIED is read from here, so it
    # can only ever be the prefix of the very command it excuses.
    assigns = []
    while i < len(argv) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[i]):
        assigns.append(argv[i])
        i += 1
    if i < len(argv) and os.path.basename(argv[i]) == "env":
        i += 1
        while i < len(argv) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[i]):
            assigns.append(argv[i])
            i += 1
    # Shell keywords and wrappers that can sit in front of the real command.
    # `if git add -A; then ...` otherwise presents `if` as argv[0] and the
    # check never fires.
    while i < len(argv) and argv[i] in PREFIX_WORDS:
        i += 1
    if i >= len(argv) or os.path.basename(argv[i]) != "git":
        return None
    i += 1

    tree = cwd
    while i < len(argv):
        a = argv[i]
        if not a.startswith("-"):
            break
        name, _, attached = a.partition("=")
        if name in GIT_GLOBAL_TREE:
            value = attached if _ else (argv[i + 1] if i + 1 < len(argv) else "")
            i += 1 if _ else 2
            if value:
                tree = value if os.path.isabs(value) else os.path.join(tree, value)
            continue
        if name in GIT_GLOBAL_VALUE:
            i += 1 if _ else 2
            continue
        i += 1
    if i >= len(argv):
        return None
    return argv[i], argv[i + 1:], tree, assigns


def check_add(args):
    i = 0
    while i < len(args):
        a = args[i]
        # Everything after `--` is a pathspec. `git add -- -A` stages a file
        # literally named -A.
        if a == "--":
            return None
        # Long options are matched EXACTLY, never by prefix, so --amend can
        # never be read as --all.
        if a in ("-A", "--all", "--no-ignore-removal"):
            return "`git add %s` stages every change in the tree, authored by this session or not." % a
        if a in ("-u", "--update"):
            return "`git add %s` stages every modification to a tracked file, authored by this session or not." % a
        if a.split("=")[0] in ADD_VALUE:
            i += 1 if "=" in a else 2
            continue
        if a.startswith("--"):
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            # Combined short cluster. -A and -u are case-distinct from -N
            # (--intent-to-add), which is allowed.
            cluster = a[1:]
            if "A" in cluster:
                return "`git add %s` includes -A, which stages every change in the tree." % a
            if "u" in cluster:
                return "`git add %s` includes -u, which stages every modification to a tracked file." % a
            i += 1
            continue
        if a in WHOLE_TREE or a.rstrip("/") in (".", ".."):
            return "`git add %s` stages the whole tree, authored by this session or not." % a
        i += 1
    return None


def check_commit(args):
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return None
        if a in ("-a", "--all"):
            return ("`git commit %s` stages every tracked modification without any `git add` at all - "
                    "the same blind staging by another spelling." % a)
        if a == "--no-verify":
            return ("`git commit --no-verify` skips .githooks/pre-commit, which is the check that "
                    "actually refuses a commit containing files this session did not author.")
        if a == "-n":
            return ("`git commit -n` is --no-verify (on commit, unlike on push), and skips "
                    ".githooks/pre-commit - the check that refuses foreign staged files.")
        if a.split("=")[0] in COMMIT_VALUE:
            i += 1 if "=" in a else 2
            continue
        if a.startswith("--"):
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            cluster = a[1:]
            if "a" in cluster:
                return ("`git commit %s` includes -a, which stages every tracked modification "
                        "without any `git add` at all." % a)
            if "n" in cluster:
                return ("`git commit %s` includes -n, which is --no-verify and skips "
                        ".githooks/pre-commit." % a)
            if cluster and cluster[-1] in COMMIT_VALUE_SHORT:
                i += 2
                continue
            i += 1
            continue
        i += 1
    return None


def escaped(assigns):
    """True when this exact command carries CLAUDE_PUSH_UNVERIFIED=1."""
    for a in assigns:
        name, _, value = a.partition("=")
        # `=1` exactly, matching CLAUDE_COMMIT_FOREIGN. A variable set to 0 or
        # to empty reads as "not this" everywhere else in the hook set, and a
        # bypass that turns on for any value at all is one an agent can trip
        # into by accident.
        if name == PUSH_ESCAPE and value == "1":
            return True
    return False


def check_push(args, assigns):
    # NOTE: `git push -n` is --dry-run, the opposite of dangerous. Only the
    # long spelling means no-verify here. The same letter means --no-verify on
    # commit; that asymmetry is git's, and conflating them would deny a
    # perfectly safe dry run.
    for a in args:
        if a == "--":
            break
        if a == "--no-verify":
            # The escape is checked HERE and not at the top, so a command that
            # carries the prefix but never asks to skip the gate is judged on
            # what it actually does.
            if escaped(assigns):
                return None
            return ("`git push --no-verify` skips .githooks/pre-push, which runs "
                    "scripts/preflight.sh - the gate that keeps a broken change off main.")
    return None


for seg in segments:
    parsed = split_git(seg)
    if not parsed:
        continue
    sub, args, tree, assigns = parsed
    # `git stage` is a synonym for `git add`; `git remote add` is not, and is
    # left alone because the subcommand is `remote`.
    #
    # The escape is passed ONLY to check_push. Handing it to the other two
    # would make one prefix excuse a `git add -A` sitting in the same command,
    # which is a different denial with a different reason and no escape at all.
    if sub in ("add", "stage"):
        problem = check_add(args)
    elif sub == "commit":
        problem = check_commit(args)
    elif sub == "push":
        problem = check_push(args, assigns)
    else:
        continue
    if not problem:
        continue
    if sub in ("add", "stage", "commit") and not overlaps_project(tree):
        # A throwaway clone outside the project, e.g. scripts/sync.sh cloning
        # each target repo into a temp dir and staging the files it wrote.
        continue
    if sub == "push":
        deny(problem, PUSH_WHY, PUSH_ALTERNATIVE)
    else:
        deny(problem, WHY)

allow()
PY
