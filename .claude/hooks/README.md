# Hooks: making the commit rule executable

The rule these files enforce:

> **Commit at every completed unit of work, staging an explicit pathspec —
> never `git add -A`, `-u`, or `.`**

The second half is the load-bearing half. It exists because of a concrete
incident: a subagent crashed mid-edit and left half a file rewritten, and
another had deliberately corrupted a source file for a falsification experiment
and never restored it. `git add -A` swept both onto `main` under the owner's
name, `_auto-merge.yml` merged it, and the deploy webhook shipped it. No stage
of that pipeline malfunctioned. The defect was the staging verb.

## What the invariant actually is

**The staged set at commit time — not the flag used to build it.**

That distinction decides which file below is the gate and which is the nudge.
`git add -A && git reset -- <foreign paths>` produces a perfectly correct
commit; a checker that judges flags cannot see that, and a checker that judges
the staged set does not care how the set was built.

| File | Event | Role |
|---|---|---|
| `../../.githooks/pre-commit` | git `pre-commit` | **The gate.** Judges the staged set. |
| `deny-blind-staging.sh` | `PreToolUse(Bash)` | Proxy + closes pre-commit's `--no-verify` hole. |
| `session-snapshot.sh` | `SessionStart` | Records the baseline; arms the gate. |
| `stop-uncommitted.sh` | `Stop` | Reminder with teeth at end of turn. |
| `_snapshot-common.sh` | — | Shared library. Not a hook. |
| `selftest.sh` | — | Acceptance test. Not a hook. |

---

## `../../.githooks/pre-commit` — the gate

Refuses a commit whose staged set contains a path that was **already dirty when
the session started** and whose **staged blob is byte-identical** to what was
sitting there then. That pair of conditions has exactly one meaning: the file is
somebody else's unfinished work and this session did not touch it. Edit the file
and it is yours again — the hashes differ, and the commit goes through.

It reads `git diff --cached --name-only -z` and compares against
`git ls-files --stage`, so it sees the bytes that would actually land on `main`,
not the working tree.

**Why this and not only the `PreToolUse` hook.** git runs it however the commit
was invoked — a script, a shell alias, `eval`, a subagent, `git commit -a`. The
`PreToolUse` hook only ever sees the top-level Bash string, so
`bash scripts/sync.sh` hides every git command inside it.

**Its one hole is `--no-verify`**, and closing that hole is the single most
important thing `deny-blind-staging.sh` does.

**The escape:**

```sh
CLAUDE_COMMIT_FOREIGN=1 git commit -m '...'
```

A block with no exit gets the hook file deleted, and then nothing is enforced.
An env prefix is one keystroke, appears verbatim in the transcript, and is
therefore a decision on the record rather than a silent bypass. Legitimate use:
the user explicitly asked for the pending changes to be committed.

**Distribution.** `scripts/install-hooks.sh` sets `core.hooksPath .githooks` and
`chmod +x`es the directory; `scripts/preflight.sh` shellchecks it;
`scripts/sync.sh` copies it to every target repository.

`.githooks/pre-commit` must appear in `sync.sh`'s `POLICY` table **and** in
`SYNC_EXEC` for the gate to reach other repositories; that is owned by the
`sync.sh` maintainer. `.claude/hooks` and `.claude/settings.json` are already
in `POLICY`, both on the `pr` lane - they execute, so they travel as a pull
request rather than a direct push. `.claude/settings.json` is the one `MERGE`
row: it is not copied over a repository's own settings, because hook entries
merge across settings levels at runtime and owning the file would destroy
configuration for nothing.

---

## `deny-blind-staging.sh` — `PreToolUse`, matcher `Bash`

Denies, with a reason the agent reads and self-corrects from:

- `git add -A` / `--all` / `-u` / `--update` / `.` / `./` / `:/` / `--no-ignore-removal`
- combined short clusters containing them — `-Av`, `-uv`, `-vA`
- `git stage <same>` (`stage` is a synonym for `add`)
- `git commit -a` / `--all` / `-am` / any cluster containing `a`
- `git commit --no-verify` / `-n` (on **commit**, `-n` *is* `--no-verify`)
- `git push --no-verify` — **unless** prefixed `CLAUDE_PUSH_UNVERIFIED=1`, see
  below (on **push**, `-n` is `--dry-run` and is **allowed** — same letter,
  opposite meaning, and conflating them would deny a safe dry run)

### The push escape

```sh
CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify
```

`../../.githooks/pre-push` has always documented `git push --no-verify` as the
emergency exit, and this hook used to deny it outright. Shipped in the same
change, that is not a strict gate — it is a promise the change itself breaks. A
pusher whose gate fails for a reason they cannot fix then has no way to push at
all, and the move that unblocks them is deleting the hook. It is not
hypothetical: run against 47 repositories' heads, the gate failed 17 of them on
pre-existing code the pusher never wrote.

Same shape and same argument as `pre-commit`'s `CLAUDE_COMMIT_FOREIGN`: one
keystroke, verbatim in the transcript, a decision **on the record** rather than
a silent bypass. Legitimate use: the gate is red for something this change did
not touch and the push cannot wait.

**Why push gets an escape when the commit-side denials do not.** They already
have one a layer down — `pre-commit` judges the staged set and takes
`CLAUDE_COMMIT_FOREIGN=1`, so refusing to *type* `git commit --no-verify` costs
nothing and the commit stays reachable on the record. Push has no second layer:
`--no-verify` means git runs no hook at all, so a denial here is the whole road
rather than a detour off it.

**Read from the command string, never from the environment.** The Bash tool's
shell is not this hook's parent, so an `export` in an earlier turn is invisible
here — and must be, since a bypass set out of sight of the command that uses it
is exactly the silent bypass this shape exists to prevent. `=1` on the very
command, or not at all. It gates that one simple command's `git push
--no-verify` and nothing else: not the segment after `&&`, not `commit`, not
`add`. All of that is pinned in `selftest.sh`.

**The refusal names it.** `permissionDecisionReason` is fed back to the model,
so it is the one place a denial can say what to do instead; the push refusal
spells out the prefix and drops the staging advice, which an agent that just
tried to push cannot act on.

### One pass, two states

The splitter walks the command string character by character, tracking
single-quote, double-quote, backslash-escape and pending-heredoc state at once.
A newline, `;`, `&&`, `||`, `|`, `(`, `)`, `<`, `>` separate simple commands
**only when every quote is closed**; a heredoc body is consumed as raw lines and
never scanned, so an apostrophe in it cannot corrupt the quote state.

Two passes cannot do this. Tokenising the whole string denies heredocs;
splitting on newlines first denies multi-line quoted arguments — and every real
commit message in this repository is multi-line, so that version blocked the
commit of this hook itself and forced a fallback to `git commit -F file`. An
agent that cannot write a commit message describing this feature deletes the
feature. Leading shell keywords and wrappers (`if`, `{`, `sudo`, `exec`, …) are
skipped so `if git add -A; then` cannot present `if` as the command.

`PreToolUse` is used because it fires **before any permission-mode check**: a
`permissionDecision: "deny"` blocks the tool even under `bypassPermissions` and
`--dangerously-skip-permissions`. It also loads in the sessions this is
distributed into. Most of them are `claude -p`, the SDK, or a cloud container,
where no trust dialog is ever shown — "Trust verification is disabled when
running non-interactively with the `-p` flag"
([security](https://code.claude.com/docs/en/security#additional-safeguards)) —
and [*What runs before you trust a folder*](https://code.claude.com/docs/en/permissions#what-runs-before-you-trust-a-folder)
lists hooks in a settings file as **Used** in exactly that case, against
`permissions.allow` and `additionalDirectories` as *not* used, with a
`this workspace has not been trusted` warning printed to stderr.

That table is about `allow`. `deny` is not on it, and the difference cuts the
other way from what this file used to claim: the `permissions.deny` list in
`../settings.json` survives an untrusted folder — "`deny` and `ask` rules
aren't affected, since they only restrict" — and survives every permission
mode, because deny rules "block in every mode, including `bypassPermissions`"
([permission modes](https://code.claude.com/docs/en/permission-modes#available-modes)).
It is not the gate for a different reason: it matches a command **prefix** and
cannot read one. `git add -v -A` and `git commit -m msg -a` are the same
commands with the flag moved, and no prefix rule sees them; and the list
carries no `--no-verify` entry at all, which is `pre-commit`'s one hole and
this hook's most important job. Free coverage for the eleven spellings it
names, in every session type — never a substitute for parsing.

### False positives are the only way this dies

Deny one legitimate `git add <path>` and the hook is gone within a week —
exactly the history `scripts/preflight.sh`'s own header recounts about a gate
that failed on the state of the machine rather than on the change. Every allow
case is pinned in `selftest.sh` next to the deny case it neighbours. **Adding a
deny without adding its neighbouring allow is how this ends up uninstalled.**

Deliberately allowed:

- `git add src/thing.py`, `git add src/ tests/`, `git add src/` — a named
  directory is an explicit pathspec
- `git add ./add-ons/x.js` — merely contains the letter sequence
- `git add -p`, `--patch`, `-i`, `-n`, `-N`, `-f`, `--renormalize`, `--chmod=`,
  `--pathspec-from-file=`
- everything after `--` — `git add -- -A` stages a file *named* `-A`
- `git -C /tmp/whatever add -A` — a throwaway clone outside the project, which
  is exactly what `scripts/sync.sh` does. `-C` is read as a directory **only
  before the subcommand**; `git commit -C <rev>` reuses a message and is left
  alone
- `git commit --amend` — long options are matched exactly, never by prefix, so
  `--amend` can never be read as `--all`
- `CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify` — the escape above.
  `CLAUDE_PUSH_UNVERIFIED=0`, an `export` in a previous command, and the name
  merely *mentioned* in the string are all still denied
- **anything inside quotes** — `git commit -m "do not use git add -A here"`,
  including a message that spans lines, contains `;` or `&&`, or quotes a whole
  heredoc. This is text in *argument* position, not a command
- heredoc **bodies** — `cat > x.sh <<'EOF' … git add -A … EOF` writes a file, it
  does not stage anything. Without this an agent could not edit `sync.sh` or
  write this README. A real command *after* the heredoc terminator is still seen
- anything that is not git (`npm add`, `docker add`) and git subcommands that
  merely contain "add" (`git remote add`, `git submodule add`, `git worktree
  add`, `git config --add`)

Deliberately **over**-refused: `git add -A && git reset -- <foreign>`. That is a
correct commit and `pre-commit` accepts it, but this hook refuses it anyway —
the corrective is only as good as the path list passed to it, and nothing in a
command string can verify that list. Name the paths instead.

---

## `session-snapshot.sh` — `SessionStart`

Two jobs.

1. **Baseline.** Records HEAD, branch, and every dirty path *with its blob hash*
   before the session touches anything. The hash is what lets `pre-commit`
   distinguish "foreign, untouched" from "foreign, then edited by me" — the
   second is legitimately this session's work.
2. **Arming.** If `.githooks/pre-commit` exists and `core.hooksPath` is unset, it
   sets it. Nobody remembers to run `scripts/install-hooks.sh` in a fresh clone
   or a fresh container, and that was the largest hole. It never overwrites an
   existing setting. It also restores the exec bit unconditionally: **git skips a
   non-executable hook silently** — no warning, no non-zero status — and `cp`
   onto an existing file leaves the destination's mode alone.

The snapshot lives **outside the repository**, under
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/tree-snapshots/`, keyed by the
repository path. Inside the tree it would itself show up as an untracked file,
the Stop hook would report it as this session's work, and sooner or later
somebody would stage it.

It uses the `cwd` field from the hook's stdin JSON, not `${CLAUDE_PROJECT_DIR}`:
**that variable does not follow into a worktree**, it stays at the directory the
session started in. Every path out of this hook exits 0 — it must never fail a
session.

---

## `stop-uncommitted.sh` — `Stop`

Replaces the blanket "commit and push everything", which is the instruction that
caused the incident. The set it asks for is `dirty now MINUS dirty at session
start`; everything in the intersection is named as explicitly **not** to commit.

- work after the baseline → exit 2, names the paths, blocks the turn
- pre-existing dirt named alongside as "NOT yours, do not commit"
- pre-existing dirt **alone** → exit 0, silent. Saying it unprompted at the end
  of every turn is noise, and noise gets hooks switched off
- **no baseline** → reports, seeds a baseline for next time, and exits 0. It
  never asks for a commit it cannot scope

---

## What this does **not** cover

Stated plainly, because a gate people over-trust is worse than one they
understand.

1. **`mcp__github__push_files` and `mcp__github__create_or_update_file` commit
   straight to the remote.** They touch neither the index nor any hook here.
   This is the largest uncovered hole, and no hook in this directory can close
   it.
2. **A crashed subagent's half-edit classifies as MINE, not foreign.** It
   happened *after* the baseline, so the Stop hook will ask the parent to commit
   it. Session-start baselining separates *pre-session* foreign work only.
   Worktree isolation is what covers the intra-session case; none of this is a
   substitute for it.
3. **"At every completed unit of work" has no hook event.** Nothing fires on
   "a unit of work just completed". That half of the rule is discipline plus the
   `Stop` reminder — not enforcement.
4. **Shell obfuscation defeats `deny-blind-staging.sh`**: `sh -c 'git add -A'`,
   aliases, `eval`, `git -c alias.x='add -A' x`, write-a-script-then-run-it. A
   stdin-parsing hook cannot resolve any of them. `pre-commit` catches the
   resulting *commit*, which is the point of having both.
5. **`--no-verify` skips the git hook entirely** — git's design, not a bug here.
   Only the `PreToolUse` deny stands between an agent and that flag, and only
   while the hook is installed. On the **push** side that deny is deliberately
   passable with `CLAUDE_PUSH_UNVERIFIED=1`, so what stands there is the record,
   not a wall. A wall with no door on the other side of it is the version that
   gets uninstalled, and then there is neither.
6. **`Stop` is not a safety net.** Claude Code overrides a `Stop` hook after
   **8 consecutive blocks**; the hook does **not fire on user interrupt**; and a
   turn ending in an API error routes to `StopFailure`, whose output is ignored.
   The most likely moment to lose work is the one moment it is guaranteed
   silent.
7. **Exotic filenames fail open.** Paths that git C-quotes (newlines,
   non-ASCII) record a `-` hash and are never blocked by `pre-commit`.
8. **No interpreter, no proxy.** `deny-blind-staging.sh` exits 0 if neither
   `python3` nor `python` is on `PATH`. Denying every Bash call because a binary
   is missing is the machine-state failure `preflight.sh`'s header is about, and
   it would be uninstalled the same day. `pre-commit` is pure bash and still
   stands.
9. **A `Stop` hook cannot be removed by user-level settings.** Hook entries
   *merge* across settings levels — a project hook is additive and a user
   setting cannot delete it.

## Verifying

```sh
bash .claude/hooks/selftest.sh    # 153 rows; exits non-zero on any failure
```

Everything runs in throwaway repositories under a temp dir with
`XDG_CACHE_HOME` redirected, so no snapshot, config, or index of the repository
under test is touched.

## Disabling in an emergency

In order of least to most destructive:

1. One commit, on the record: `CLAUDE_COMMIT_FOREIGN=1 git commit -m '...'`
2. One push, on the record: `CLAUDE_PUSH_UNVERIFIED=1 git push --no-verify`
3. One commit, skipping `pre-commit` entirely: `git commit --no-verify`
   (`deny-blind-staging.sh` will refuse to *type* this for you, and unlike the
   push case there is no prefix that changes its mind — the commit is still
   reachable through 1)
4. This repository, until re-armed: `git config --unset core.hooksPath` —
   note `session-snapshot.sh` re-arms it at the next session start
5. All of it: delete the `hooks` block from `.claude/settings.json`. Hook entries
   merge across settings levels, so a **project** hook cannot be switched off
   from user-level settings — it has to be removed here

Reaching for 1 or 2 routinely means one of two things. If the gate is red for
something your change never touched — the state of the machine, or code that was
already broken when you cloned it — that is a bug in the gate, and it wants
reporting rather than a habit. If it is red for what you actually changed, the
gate is working and the bypass is a choice to ship it anyway; that is sometimes
right, and the prefix is why anyone can tell the two apart afterwards.
