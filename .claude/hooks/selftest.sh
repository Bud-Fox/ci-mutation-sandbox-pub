#!/usr/bin/env bash
#
# Acceptance test for the hook set. Run it after touching any hook:
#
#   bash .claude/hooks/selftest.sh
#
# NOT A HOOK - nothing in settings.json points here.
#
# WHY IT IS COMMITTED RATHER THAN THROWN AWAY
# The deny hook lives or dies on its FALSE POSITIVES. Refuse one legitimate
# `git add <path>` and the hook is deleted within a week, which is exactly the
# history scripts/preflight.sh's header recounts about a gate that failed on
# the state of the machine rather than on the change. So every allow-case is
# pinned here next to the deny-case it neighbours. Adding a deny without adding
# its neighbouring allow is how this ends up uninstalled.
#
# Everything runs in throwaway repositories under a temp dir with
# XDG_CACHE_HOME redirected, so no snapshot, config, or index of the repository
# under test is touched.
#
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$ROOT/.claude/hooks"
DENY="$HOOKS/deny-blind-staging.sh"
SNAPSHOT="$HOOKS/session-snapshot.sh"
STOP="$HOOKS/stop-uncommitted.sh"
PRECOMMIT="$ROOT/.githooks/pre-commit"

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
export XDG_CACHE_HOME="$WORK/cache"
export CLAUDE_PROJECT_DIR="$ROOT"
unset CLAUDE_COMMIT_FOREIGN

PASS=0
FAIL=0

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; B=""; N=""; fi

row() {  # expected actual description
  local expected="$1" actual="$2" desc="$3" mark
  if [ "$expected" = "$actual" ]; then
    mark="${G}PASS${N}"; PASS=$((PASS + 1))
  else
    mark="${R}FAIL${N}"; FAIL=$((FAIL + 1))
  fi
  printf '  %b  %-6s %-6s  %s\n' "$mark" "$expected" "$actual" "$desc"
}

# ------------------------------------------------------------------------- #
# 1. deny-blind-staging.sh - the table that matters
# ------------------------------------------------------------------------- #
mkjson() {
  python3 -c 'import json,sys
print(json.dumps({
  "session_id": "selftest",
  "transcript_path": "/dev/null",
  "cwd": sys.argv[1],
  "hook_event_name": "PreToolUse",
  "tool_name": sys.argv[2],
  "tool_input": {"command": sys.argv[3]},
  "tool_use_id": "toolu_selftest",
}))' "$1" "$2" "$3"
}

decision() {  # command [tool_name] -> deny|allow
  local out
  out="$(mkjson "$ROOT" "${2:-Bash}" "$1" | bash "$DENY" 2>/dev/null)"
  case "$out" in
    *'"deny"'*) printf 'deny' ;;
    *)          printf 'allow' ;;
  esac
}

# Pairs: expected, command. Kept as pairs rather than a delimited line so a
# command containing |, ;, or a newline needs no escaping.
CASES=(
  # ---- MUST DENY: blind staging -----------------------------------------
  deny  'git add -A'
  deny  'git add --all'
  deny  'git add .'
  deny  'git add -u'
  deny  'git add --update'
  deny  'git add -Av'
  deny  'git add -uv'
  deny  'git add -vA'
  deny  'git add --no-ignore-removal'
  deny  'git stage -A'
  deny  'git add ./'
  deny  'git add :/'
  deny  'cd src && git add -A'
  deny  'git status --porcelain; git add -A'
  # ---- MUST DENY: commit -a and friends ---------------------------------
  deny  'git commit -a'
  deny  'git commit --all'
  deny  'git commit -am "wip"'
  deny  'git commit -a -m "wip"'
  deny  'git commit -avm "wip"'
  # ---- MUST DENY: --no-verify -------------------------------------------
  deny  'git commit --no-verify -m "wip"'
  deny  'git commit -n -m "wip"'
  deny  'git commit -nm "wip"'
  deny  'git push --no-verify'
  deny  'git push --no-verify origin HEAD'
  # ---- MUST ALLOW: explicit pathspecs ------------------------------------
  allow 'git add path/to/file.py'
  allow 'git add src/ tests/'
  allow 'git add src/'
  allow 'git add ./add-ons/x.js'
  allow 'git add ./add-ons/'
  allow 'git add -- -A'
  allow 'git add -- .'
  allow 'git add a.py b.py c.py'
  # ---- MUST ALLOW: interactive and harmless add flags --------------------
  allow 'git add -p'
  allow 'git add --patch'
  allow 'git add -i'
  allow 'git add --interactive'
  allow 'git add -n src/x.py'
  allow 'git add -N src/new.py'
  allow 'git add --intent-to-add src/new.py'
  allow 'git add -f build/artifact.bin'
  allow 'git add --renormalize src/x.py'
  allow 'git add --chmod=+x scripts/x.sh'
  allow 'git add --chmod +x scripts/x.sh'
  allow 'git add --pathspec-from-file=paths.txt'
  # ---- MUST ALLOW: outside the project -----------------------------------
  allow 'git -C /tmp/whatever add -A'
  allow 'git -C /tmp/sync-clone.XXXX commit -am "sync"'
  allow 'git --git-dir=/tmp/clone/.git --work-tree=/tmp/clone add -A'
  # ---- MUST ALLOW: not git, or git but not these subcommands -------------
  allow 'npm add lodash'
  allow 'docker add whatever'
  allow 'yarn add -A'
  allow 'git remote add origin git@github.com:o/r.git'
  allow 'git remote add -f upstream https://example.invalid/r.git'
  allow 'git submodule add https://example.invalid/r.git vendor/r'
  allow 'git worktree add ../wt -b topic'
  allow 'git config --add alias.st status'
  allow 'git log --all --oneline'
  allow 'git diff --cached --name-only'
  # ---- MUST ALLOW: commit spellings that are not -a -----------------------
  allow 'git commit -m "wip"'
  allow 'git commit -m "add -A support to the docs"'
  allow 'git commit --amend --no-edit'
  allow 'git commit -C HEAD'
  allow 'git commit -C HEAD~1 --reset-author'
  allow 'git commit -sm "signed"'
  allow 'git commit --author="A U Thor <a@example.invalid>" -m x'
  allow 'git commit -m "commit -a is banned here"'
  # ---- MUST ALLOW: push spellings that are not --no-verify ---------------
  allow 'git push -n'
  allow 'git push --dry-run'
  allow 'git push origin HEAD'
  allow 'git push --force-with-lease'
  # ---- THE PUSH ESCAPE ---------------------------------------------------
  # .githooks/pre-push documents `git push --no-verify` as the emergency exit.
  # Denying it outright made that promise false and left a pusher whose gate
  # fails on code they did not write with no way to push at all - and the fix
  # such a pusher reaches for is deleting the hook. The prefix is the same
  # shape as .githooks/pre-commit's CLAUDE_COMMIT_FOREIGN: one keystroke,
  # verbatim in the transcript, a decision on the record.
  allow 'CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify'
  allow 'CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify origin HEAD'
  allow 'env CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify'
  allow 'CLAUDE_PUSH_UNVERIFIED=1 git -c push.default=current push --no-verify'
  allow 'CLAUDE_PUSH_UNVERIFIED=1 git push origin HEAD'
  # ---- THE ESCAPE ONLY WHERE IT WAS TYPED --------------------------------
  # A bypass that is set out of sight of the command it excuses is the silent
  # bypass the shape exists to prevent, so only `=1` on this very command
  # counts. `export` in an earlier turn is not even visible to this hook.
  deny  'CLAUDE_PUSH_UNVERIFIED=0 git push --no-verify'
  deny  'CLAUDE_PUSH_UNVERIFIED= git push --no-verify'
  deny  'CLAUDE_PUSH_UNVERIFIED=yes git push --no-verify'
  deny  'export CLAUDE_PUSH_UNVERIFIED=1; git push --no-verify'
  deny  'echo CLAUDE_PUSH_UNVERIFIED=1 && git push --no-verify'
  deny  'git push --no-verify CLAUDE_PUSH_UNVERIFIED=1'
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify && git add -A'
  # ---- THE ESCAPE LOOSENS NOTHING ON THE COMMIT OR STAGING SIDE ----------
  # Those denials keep no escape because they already have one a layer down:
  # the commit itself is still reachable through .githooks/pre-commit's
  # CLAUDE_COMMIT_FOREIGN. Push has no second layer, which is the whole reason
  # it needs an exit and they do not.
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git commit --no-verify -m "wip"'
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git commit -n -m "wip"'
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git commit -am "wip"'
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git add -A'
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git add .'
  deny  'CLAUDE_PUSH_UNVERIFIED=1 git stage -u'
  # naming the escape in a commit message is still text, not a command
  allow 'git commit -m "CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify"'
  # ---- MUST ALLOW: heredoc bodies are content, not commands --------------
  allow $'cat > x.sh <<\'EOF\'\ngit add -A\nEOF\n'
  allow $'cat > x.sh <<EOF\ngit commit -am "x"\nEOF\n'
  allow $'cat > x.sh <<-EOF\n\tgit add -A\n\tEOF\n'
  allow $'cat > x.md <<"DOC"\ngit push --no-verify\nDOC\n'
  allow $'cat >> a.sh <<\'A\'\ngit add -A\nA\ncat >> b.sh <<\'B\'\ngit add -u\nB\n'
  # a heredoc body must not blind the hook to a REAL command after it
  deny  $'cat > x.sh <<\'EOF\'\nharmless\nEOF\ngit add -A\n'
  # ---- DELIBERATE OVER-REFUSAL, pinned as intended behaviour -------------
  # `git add -A && git reset -- <foreign>` is a CORRECT commit and
  # .githooks/pre-commit accepts it (see section 3). This layer refuses it
  # anyway: the corrective is only as good as the path list passed to it, and
  # nothing in a command string can verify that list. Not a known failure - the
  # intended answer.
  deny  'git add -A && git reset -- vendor/foreign.py'
  deny  'git add -A && git reset -- .'
  # ---- MUST ALLOW: a quoted ARGUMENT is text, never a command ------------
  # This class blocked a real commit of this very hook and forced a fallback
  # to `git commit -F file`. An agent that cannot write a commit message, a
  # README, or a code comment naming the forbidden spellings deletes the hook.
  allow 'git commit -m "do not use git add -A here"'
  allow 'git commit -m "see .claude/hooks/deny-blind-staging.sh; git add -A is denied"'
  allow 'git commit -m "a; b && c"'
  allow "git commit -m \$'line one\\ngit add -A\\nline three'"
  allow $'git commit -m "line one\ngit add -A\nline three"'
  allow $'git commit -m "fix\ngit add -A          <- allowed\ndone"'
  allow $'git commit -q -m "fix" -m "the heredoc stripper\ngit add -A          <- allowed\ndone"'
  allow $'git commit -m "...\n   cat > x.sh <<\'EOF\'\n   harmless\n   EOF\n   git add -A          <- allowed\n..."'
  allow $'git commit -m "line one\ngit add -A\nline three"\n'
  allow 'echo '"'"'git add -A'"'"' > notes.txt'
  allow $'printf \'%s\\n\' "git add -A" >> .claude/hooks/README.md'
  # a heredoc body may contain an unbalanced quote without blinding the parser
  allow $'cat > x <<\'EOF\'\nit\'s fine\nEOF\ngit add src/f.py'
  deny  $'cat > x <<\'EOF\'\nit\'s fine\nEOF\ngit add -A'
  # separators OUTSIDE quotes still separate
  deny  'git commit -m "msg" && git add -A'
  deny  'git add -A; git commit -m "x"'
  deny  'git commit -m "quoted; text" && git add -A'
  deny  $'git commit -m "line one\ngit add src/x.py\nline three"\ngit add -A'
  # shell keywords in front of the real command
  deny  'if git add -A; then echo ok; fi'
  deny  '{ git add -A; }'
  deny  'sudo git add -A'
  allow 'if git add src/x.py; then echo ok; fi'
  # ---- MUST ALLOW: quoted mentions, and the documented obfuscation hole ---
  allow 'echo "git add -A"'
  allow 'grep -n "git add -A" .claude/hooks/README.md'
  allow 'sh -c "git add -A"'
  allow 'bash scripts/sync.sh'
  # ---- MUST ALLOW: other tools are none of this hook'"'"'s business ---------
)

printf '\n%s1. deny-blind-staging.sh (PreToolUse, matcher Bash)%s\n' "$B" "$N"
printf '  %-6s %-6s %-6s  %s\n' 'result' 'want' 'got' 'command'
i=0
while [ $i -lt ${#CASES[@]} ]; do
  want="${CASES[$i]}"
  cmd="${CASES[$((i + 1))]}"
  got="$(decision "$cmd")"
  row "$want" "$got" "$(printf '%s' "$cmd" | tr '\n' '~')"
  i=$((i + 2))
done

# A non-Bash tool must never be touched, whatever its input looks like.
got="$(decision 'git add -A' 'Write')"
row allow "$got" 'tool_name=Write (not Bash) with a git add -A payload'

# The reason text, not just the verdict. permissionDecisionReason is fed back
# to the model, so it is the only place a refusal can tell the agent what to do
# instead. A refusal an agent cannot act on gets the hook file deleted, which
# is how every allow-case above stops being enforced at all.
reason() {  # command -> permissionDecisionReason, empty string when allowed
  mkjson "$ROOT" Bash "$1" | bash "$DENY" 2>/dev/null | python3 -c 'import json,sys
s = sys.stdin.read().strip()
sys.stdout.write(json.loads(s)["hookSpecificOutput"]["permissionDecisionReason"] if s else "")'
}

PR="$(reason 'git push --no-verify')"
case "$PR" in
  *'CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify'*) g=yes ;; *) g=no ;;
esac
row yes "$g" 'push refusal spells out the escape it will accept'
# Answering a push with "stage an explicit pathspec" is advice the agent cannot
# act on, and the pusher is then out of moves for the second time in one turn.
case "$PR" in *'git status --porcelain'*) g=leaked ;; *) g=clean ;; esac
row clean "$g" 'push refusal does not hand back the staging advice'
case "$(reason 'git commit --no-verify -m "wip"')" in
  *CLAUDE_PUSH_UNVERIFIED*) g=leaked ;; *) g=clean ;;
esac
row clean "$g" 'commit refusal never advertises the push escape'

# ------------------------------------------------------------------------- #
# 2. session-snapshot.sh + stop-uncommitted.sh
# ------------------------------------------------------------------------- #
newrepo() {  # -> path
  local d="$WORK/repo.$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email selftest@example.invalid
  git -C "$d" config user.name selftest
  echo base >"$d/tracked.txt"
  git -C "$d" add tracked.txt >/dev/null 2>&1
  git -C "$d" -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
  printf '%s' "$d"
}

run_hook() {  # script cwd -> writes stdout to $WORK/out, stderr to $WORK/err
  local script="$1" cwd="$2"
  python3 -c 'import json,sys
print(json.dumps({"session_id":"selftest","transcript_path":"/dev/null",
                  "cwd":sys.argv[1],"hook_event_name":"x","stop_hook_active":False}))' "$cwd" \
    | bash "$script" >"$WORK/out" 2>"$WORK/err"
  printf '%s' "$?"
}

printf '\n%s2. session-snapshot.sh + stop-uncommitted.sh%s\n' "$B" "$N"
printf '  %-6s %-6s %-6s  %s\n' 'result' 'want' 'got' 'scenario'

# 2a. clean tree, snapshot taken, nothing changed -> silent exit 0
R1="$(newrepo a)"
run_hook "$SNAPSHOT" "$R1" >/dev/null
rc="$(run_hook "$STOP" "$R1")"
row 0 "$rc" 'clean tree after snapshot -> exit 0'
row '' "$(cat "$WORK/err")" 'clean tree -> says nothing on stderr'

# 2b. a file dirty BEFORE the snapshot, and nothing else -> no block
R2="$(newrepo b)"
echo foreign >>"$R2/tracked.txt"
echo foreign >"$R2/untracked-foreign.txt"
run_hook "$SNAPSHOT" "$R2" >/dev/null
rc="$(run_hook "$STOP" "$R2")"
row 0 "$rc" 'only pre-existing dirt -> exit 0 (does not block)'
case "$(cat "$WORK/err")" in
  '') row quiet quiet 'only pre-existing dirt -> no demand to commit' ;;
  *)  row quiet noisy 'only pre-existing dirt -> no demand to commit' ;;
esac

# 2c. a file dirty AFTER the snapshot -> block, name mine, name theirs
R3="$(newrepo c)"
echo foreign >>"$R3/tracked.txt"
run_hook "$SNAPSHOT" "$R3" >/dev/null
echo mine >"$R3/mine.txt"
rc="$(run_hook "$STOP" "$R3")"
row 2 "$rc" 'dirty after snapshot -> exit 2 (blocks the turn)'
case "$(cat "$WORK/err")" in *mine.txt*) g=yes ;; *) g=no ;; esac
row yes "$g" 'names mine.txt as this session'"'"'s work'
case "$(cat "$WORK/err")" in *"NOT yours"*) g=yes ;; *) g=no ;; esac
row yes "$g" 'says the pre-existing file is NOT this session'"'"'s'
case "$(cat "$WORK/err")" in *tracked.txt*) g=yes ;; *) g=no ;; esac
row yes "$g" 'names tracked.txt in the do-not-commit group'

# 2d. no snapshot at all -> report, never demand
R4="$(newrepo d)"
echo whatever >"$R4/orphan.txt"
rc="$(run_hook "$STOP" "$R4")"
row 0 "$rc" 'no snapshot -> exit 0 (degrades to reporting)'
case "$(cat "$WORK/out")" in *"do NOT commit these wholesale"*) g=yes ;; *) g=no ;; esac
row yes "$g" 'no snapshot -> refuses to demand a blind commit'

# 2e. detached HEAD is representable
R5="$(newrepo e)"
git -C "$R5" checkout -q --detach 2>/dev/null
run_hook "$SNAPSHOT" "$R5" >/dev/null
SNAPFILE="$XDG_CACHE_HOME/claude-code-hooks/tree-snapshots/${R5//\//%}.snapshot"
case "$(sed -n 's/^branch //p' "$SNAPFILE" 2>/dev/null)" in
  DETACHED) g=yes ;; *) g=no ;;
esac
row yes "$g" 'detached HEAD recorded as branch DETACHED'

# 2f. a non-git cwd must not fail the session
rc="$(run_hook "$SNAPSHOT" "$WORK")"
row 0 "$rc" 'non-git cwd -> snapshot hook exits 0'
rc="$(run_hook "$STOP" "$WORK")"
row 0 "$rc" 'non-git cwd -> stop hook exits 0'

# 2g. arming: core.hooksPath is set when unset and pre-commit exists
R6="$(newrepo f)"
mkdir -p "$R6/.githooks" "$R6/.claude/hooks"
cp "$PRECOMMIT" "$R6/.githooks/pre-commit"
chmod -x "$R6/.githooks/pre-commit"
cp "$HOOKS/_snapshot-common.sh" "$R6/.claude/hooks/"
run_hook "$SNAPSHOT" "$R6" >/dev/null
row .githooks "$(git -C "$R6" config --get core.hooksPath)" 'arms core.hooksPath when unset'
[ -x "$R6/.githooks/pre-commit" ] && g=yes || g=no
row yes "$g" 'restores the exec bit git needs to run the hook at all'

# 2h. arming never overwrites an existing choice
R7="$(newrepo g)"
mkdir -p "$R7/.githooks" "$R7/.claude/hooks"
cp "$PRECOMMIT" "$R7/.githooks/pre-commit"
cp "$HOOKS/_snapshot-common.sh" "$R7/.claude/hooks/"
git -C "$R7" config core.hooksPath .myhooks
run_hook "$SNAPSHOT" "$R7" >/dev/null
row .myhooks "$(git -C "$R7" config --get core.hooksPath)" 'never overwrites an existing core.hooksPath'

# ------------------------------------------------------------------------- #
# 3. .githooks/pre-commit - the load-bearing check
# ------------------------------------------------------------------------- #
printf '\n%s3. .githooks/pre-commit (the staged set, however the commit was invoked)%s\n' "$B" "$N"
printf '  %-6s %-6s %-6s  %s\n' 'result' 'want' 'got' 'scenario'

hookrepo() {  # -> path, with the hook set installed, armed, and COMMITTED
  local d
  d="$(newrepo "$1")"
  mkdir -p "$d/.githooks" "$d/.claude/hooks"
  cp "$PRECOMMIT" "$d/.githooks/pre-commit"
  chmod +x "$d/.githooks/pre-commit"
  cp "$HOOKS/_snapshot-common.sh" "$d/.claude/hooks/"
  # The hook files must be COMMITTED, not left sitting untracked. Untracked
  # they are dirty, so they land in the baseline, so any later `git add -A`
  # stages them and pre-commit correctly refuses - and the scenario under test
  # fails for a reason that has nothing to do with what it is testing. This
  # setup commit is the one place core.hooksPath is bypassed, deliberately:
  # there is no baseline yet for the hook to consult.
  git -C "$d" -c core.hooksPath=/dev/null add .githooks .claude >/dev/null 2>&1
  git -C "$d" -c core.hooksPath=/dev/null commit -qm "install hooks" >/dev/null 2>&1
  git -C "$d" config core.hooksPath .githooks
  printf '%s' "$d"
}

commit_rc() {  # repo -> exit status of a commit attempt
  git -C "$1" commit -qm "selftest" >"$WORK/out" 2>"$WORK/err"
  printf '%s' "$?"
}

# 3a. staging a file that was already dirty and is untouched -> refused
P1="$(hookrepo p1)"
echo "somebody else's half-edit" >>"$P1/tracked.txt"
run_hook "$SNAPSHOT" "$P1" >/dev/null
git -C "$P1" add tracked.txt
rc="$(commit_rc "$P1")"
[ "$rc" = 0 ] && g=allowed || g=refused
row refused "$g" 'foreign file, byte-identical to the baseline -> commit refused'
case "$(cat "$WORK/err")" in *tracked.txt*) g=yes ;; *) g=no ;; esac
row yes "$g" 'names the offending path'
case "$(cat "$WORK/err")" in *CLAUDE_COMMIT_FOREIGN*) g=yes ;; *) g=no ;; esac
row yes "$g" 'names the on-the-record escape'

# 3b. the SAME staged set reached via `git add -A` is refused identically,
#     which is the point: the check is on the staged set, not on the verb.
P2="$(hookrepo p2)"
echo "somebody else's half-edit" >>"$P2/tracked.txt"
run_hook "$SNAPSHOT" "$P2" >/dev/null
echo mine >"$P2/mine.txt"
git -C "$P2" add -A
rc="$(commit_rc "$P2")"
[ "$rc" = 0 ] && g=allowed || g=refused
row refused "$g" 'git add -A that swept a foreign file -> commit refused'

# 3c. `git add -A && git reset -- <foreign>` is a CORRECT commit and passes
P3="$(hookrepo p3)"
echo "somebody else's half-edit" >>"$P3/tracked.txt"
run_hook "$SNAPSHOT" "$P3" >/dev/null
echo mine >"$P3/mine.txt"
git -C "$P3" add -A
git -C "$P3" reset -q -- tracked.txt
rc="$(commit_rc "$P3")"
[ "$rc" = 0 ] && g=allowed || g=refused
row allowed "$g" 'add -A then reset the foreign path -> commit allowed'

# 3d. a foreign file this session then EDITED is this session's work
P4="$(hookrepo p4)"
echo "somebody else's half-edit" >>"$P4/tracked.txt"
run_hook "$SNAPSHOT" "$P4" >/dev/null
echo "and my finished edit" >>"$P4/tracked.txt"
git -C "$P4" add tracked.txt
rc="$(commit_rc "$P4")"
[ "$rc" = 0 ] && g=allowed || g=refused
row allowed "$g" 'foreign file edited by this session -> commit allowed'

# 3e. an ordinary new file
P5="$(hookrepo p5)"
run_hook "$SNAPSHOT" "$P5" >/dev/null
echo mine >"$P5/mine.txt"
git -C "$P5" add mine.txt
rc="$(commit_rc "$P5")"
[ "$rc" = 0 ] && g=allowed || g=refused
row allowed "$g" 'ordinary new file -> commit allowed'

# 3f. no snapshot -> nothing to judge against, never block
P6="$(hookrepo p6)"
echo whatever >>"$P6/tracked.txt"
git -C "$P6" add tracked.txt
rc="$(commit_rc "$P6")"
[ "$rc" = 0 ] && g=allowed || g=refused
row allowed "$g" 'no baseline -> commit allowed (never blocks on missing state)'

# 3g. the escape works and announces itself
P7="$(hookrepo p7)"
echo "somebody else's half-edit" >>"$P7/tracked.txt"
run_hook "$SNAPSHOT" "$P7" >/dev/null
git -C "$P7" add tracked.txt
CLAUDE_COMMIT_FOREIGN=1 git -C "$P7" commit -qm escape >"$WORK/out" 2>"$WORK/err"
rc=$?
[ "$rc" = 0 ] && g=allowed || g=refused
row allowed "$g" 'CLAUDE_COMMIT_FOREIGN=1 -> commit allowed'
case "$(cat "$WORK/err")" in *"deliberately bypassed"*) g=yes ;; *) g=no ;; esac
row yes "$g" 'the escape says so on the record'

# 3h. the hole the PreToolUse hook exists to close
P8="$(hookrepo p8)"
echo "somebody else's half-edit" >>"$P8/tracked.txt"
run_hook "$SNAPSHOT" "$P8" >/dev/null
git -C "$P8" add tracked.txt
git -C "$P8" commit -q --no-verify -m bypass >"$WORK/out" 2>"$WORK/err"
rc=$?
[ "$rc" = 0 ] && g=allowed || g=refused
row allowed "$g" '--no-verify walks past pre-commit (why the PreToolUse deny exists)'

# 3i. a commit reached through a script file, invisible to any string parser
P9="$(hookrepo p9)"
echo "somebody else's half-edit" >>"$P9/tracked.txt"
run_hook "$SNAPSHOT" "$P9" >/dev/null
printf '#!/usr/bin/env bash\ncd "$1" || exit 1\ngit add -A\ngit commit -qm hidden\n' >"$WORK/hidden.sh"
bash "$WORK/hidden.sh" "$P9" >"$WORK/out" 2>"$WORK/err"
rc=$?
[ "$rc" = 0 ] && g=allowed || g=refused
row refused "$g" 'git add -A hidden inside a script -> still refused at commit'

# ------------------------------------------------------------------------- #
printf '\n%s%s passed, %s failed%s\n\n' "$B" "$PASS" "$FAIL" "$N"

# Explicit, so this is usable as a check and not only as a report: any failing
# row exits non-zero.
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
