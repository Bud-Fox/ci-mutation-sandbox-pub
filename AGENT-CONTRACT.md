# Agent contract - Bud-Fox repositories

Synced from `Bud-Fox/.github`. Do not edit in place; edit the source and re-sync.

## First command in every fresh clone or container

```
bash scripts/install-hooks.sh
```

This points git at the tracked `.githooks` directory and builds a cached
`.preflight-venv` with this repository's dependencies. Both halves matter: the
hook without the venv can only run the cheap checks, because the gate skips a
stage rather than failing on a machine that lacks a library.

A session that skips this line is a session where CI is the first thing to see
a defect. In the 60 days to 2026-08-23 that accounted for 48 of 159 failed
runs, all of them catchable locally in seconds.

## The gate

`scripts/preflight.sh` runs before every push, and the same file is the only
step in the reusable CI workflow. That is the whole design: a local pass and a
CI pass cannot disagree, because there is one script.

Add a check to that script, never to a workflow yaml.

Two properties keep it trusted, and both are worth preserving:

- It fails on what you changed, never on the state of the machine. A missing
  library produces a named `skip`, not a red.
- It detects conventions instead of assuming them. Migration numbering is read
  from the files already in the tree, so `20260817120000_` and `001_` are both
  correct in the repository that chose them.

A fact only this repository can know goes in `.preflight.conf` at the root -
for example a test suite that needs live API credentials and must be deselected
until it learns to skip itself. Never edit the shared script for a local fact.

## Commits

**Commit at every completed unit of work, staging an explicit pathspec - never
`git add -A`, `-u`, or `.`**

Both halves are load-bearing, and for unrelated reasons.

*At every completed unit* is about what survives. A session or a subagent that
dies mid-task takes the uncommitted tree with it, and what is lost is everything
since the last commit. Committing at each finished unit bounds that to one unit
instead of a session. This is the same argument as the one against a branch
nobody integrates, one level down.

*Explicit pathspec* is about what gets in. `git add -A`, `git add -u` and
`git add .` stage what is in the tree, which is not the same set as what you
decided to change. `git commit -a` is the same defect with the `git add` removed
entirely - it stages every tracked modification - so it is forbidden on the same
grounds. Name the paths and the commit can contain only what you named: a
crashed subagent's half-written file, a scratch script, an `.env` somebody
dropped in the tree, or a source file corrupted on purpose while you worked
cannot ride in behind a commit you believed was yours.

### What enforces this, and what does not

| half of the rule | enforcement |
|---|---|
| explicit pathspec | **Enforced.** A `PreToolUse` hook matches the blind-staging forms and denies the call before the command runs. `PreToolUse` fires ahead of the tool whatever the permission mode is, so `acceptEdits` and `--dangerously-skip-permissions` do not get around it. |
| at every completed unit | **Not enforced - discipline, with a reminder at best.** No hook event corresponds to "a unit of work finished". `Stop` is end-of-turn, a different boundary that can hold six units or none. `PostToolUse` on `Edit` is per file, smaller than a unit, and would fire on every one. |

That asymmetry is the honest description. The first half you cannot get wrong;
the second half nothing will catch for you, so it is yours to keep.

Worth stating rather than assuming, because this repository was already doing
it: `scripts/sync.sh` staged its commit with `git add -A` for every consuming
repo. It was safe, but only because the tree it ran in was a fresh `mktemp -d`
clone with nothing else in it - safe by where it happened to run, not because
anyone had decided it was. It now stages the list of paths it copied.

## What this repository runs in your session

`.claude/settings.json` arrives with the sync and registers three hooks. They
execute unprompted - at session start, before every Bash call, and at the end
of a turn - and in a `-p`, SDK or cloud session there is no trust dialog and no
opt-in step in front of them: hooks in a project settings file are listed
**Used** in the `claude -p`/SDK column of [What runs before you trust a
folder](https://code.claude.com/docs/en/permissions#what-runs-before-you-trust-a-folder),
and "Trust verification is disabled when running non-interactively with the
`-p` flag"
([security](https://code.claude.com/docs/en/security#additional-safeguards)).
That is worth stating here rather than leaving to be discovered.

| hook | event | what it does |
|---|---|---|
| `session-snapshot.sh` | `SessionStart` | Records HEAD and every already-dirty path with its blob hash, and points `core.hooksPath` at `.githooks` when nothing has set it. |
| `deny-blind-staging.sh` | `PreToolUse(Bash)` | Reads the command string and refuses `git add -A`/`-u`/`.`, `git commit -a`, and `--no-verify` on commit and push. It refuses nothing else. |
| `stop-uncommitted.sh` | `Stop` | Compares the tree against that baseline and blocks the turn while this session's own work is uncommitted. |

None of them makes a network call. The single write outside the repository is
local hook state, isolated per repository under
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/`, and it is there because
inside the tree it would read as untracked work and eventually be staged. That
is the standing rule for anything added here: no network, and no write anywhere
but that cache directory.

**Named exception (owner decision 2026-10-17): the model-routing ledger hooks.**
Exactly two hooks are exempt from the standing rule above, and only for what is
listed here: `.claude/hooks/agent_token_ledger.py` and
`.claude/hooks/session_budget.py` (rule `token-ledger v2` in the rules canon,
`rules/model-routing.md`). Each may open one database connection over
`AGENT_LEDGER_DATABASE_URL` or, when that is unset, `DATABASE_URL`, with a 4 s
connect timeout: `agent_token_ledger.py` makes one INSERT into
`agent_token_ledger` per finished subagent, and `session_budget.py` makes one
SELECT from `agent_token_ledger` at session start. Routing journals, async
pending/done state and guard decisions are written only below
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-hooks/agent-routing/<project-sha256>/`,
under the standing cache-only rule. The project key is the SHA256 of its
resolved absolute path. Reading the local budget creates no files. Hooks do
not write Python bytecode beside tracked scripts. Historical `.claude/ledger/`
files are neither deleted nor automatically migrated; local totals begin in
the new cache. No repository-local journal write is permitted. Neither hook
makes any other network call. Any failure - no variable, no driver, a refused
or slow connection, a malformed payload - exits 0 and prints one line to stderr
naming what failed; a written local cache journal line is kept.
No other hook, present or future, inherits this exception: a new hook that needs
the network or a write outside the cache directory needs its own named entry here.

### Turning them off

- `--setting-sources user`, or the SDK's `settingSources` without project
  settings - none of this repository's settings files or its `.mcp.json` is read
- `--bare` - no hooks, skills, commands, subagents or plugins from the project
- `--settings '{"disableAllHooks": true}'`, **on the command line**. Setting it
  in user settings alone is not enough: Claude Code "reads the value left after
  settings precedence applies, so a `"disableAllHooks": false` in a project's
  `.claude/settings.json` overrides a `true` in your user settings"
  ([hooks](https://code.claude.com/docs/en/hooks#disable-or-remove-hooks)).
  Nothing here sets that key, and the flag is the form that does not depend on
  that staying true.

## Skills

`.claude/skills/` is checked into this repository, so a cloud session, a GitHub
Action and a local terminal all load the same set from the clone - there is no
install step to forget. Each skill declares a `description` beginning "Use
when", and that line is the trigger: match the task in front of you against it
and read the skill before starting, without waiting to be told.

| When the task is | Use |
|------------------|-----|
| a spec or a multi-step request, before any code | `writing-plans` |
| a written plan, tasks independent, this session | `subagent-driven-development` |
| a written plan, executed in a session of its own | `executing-plans` |
| any feature or bugfix, before the implementation | `test-driven-development` |
| a bug, a red test, or behaviour you cannot explain | `systematic-debugging` |
| about to call something done, fixed, or passing | `verification-before-completion` |

The last two are the ones this account keeps paying for. Of 159 failed runs in
the 60 days to 2026-08-23, the `DNB-MCP` container-name pile-up was four PRs
that each fixed a symptom because none of them looked for the root cause, and
the repeated red builds were work called finished without the command being run
once. Both are what these two skills exist to stop.

Never edit a file under `.claude/skills/` - it is vendored and
`scripts/vendor-skills.sh` overwrites the tree on the next refresh, without a
diff anyone will notice. A rule that is ours and not upstream's goes here
instead, which is what the next two are.

### Declared preferences

The skills are written to defer to preferences stated in your instructions.
These are those preferences; they are not edits to the skills.

**Workspace.** Do not ask whether to create a worktree, and do not create one
by default. A cloud session already holds an isolated ephemeral container with
a clone of its own, so a worktree there buys nothing and the consent question
in `using-git-worktrees` has nobody to answer.

The exception used to read "only when you are about to run two lines of work
over the same tree at once". That is the right condition and it has never once
fired, because nobody recognises the moment they are in as an instance of it.
Named concretely, it is this: **dispatching more than one writing subagent at a
time is that case.** Give each of them a worktree of its own, through the
harness's native worktree support - never `git worktree add` on top of a native
tool, which leaves state the harness cannot see or clean up. One subagent, or
several that only read, still needs nothing. `.worktrees/` is gitignored here
already, so `using-git-worktrees` will not take its fallback branch and commit
a `.gitignore` change before it starts.

This overrides `subagent-driven-development`, whose `SKILL.md:282` reads "Never
dispatch multiple implementation subagents in parallel (conflicts)". The reason
it gives is the whole of its case, and a worktree each removes the conflict - it
was a workaround for isolation the skill could not assume, not a finding about
parallelism. **The rule here governs: parallel writing subagents are permitted
when each holds its own worktree, and forbidden when they would share a tree.**
Nothing else in that skill changes - one task per dispatch, the review loop and
the ledger all still apply, and each subagent still commits its own work on the
explicit-pathspec rule above, which is what makes merging the worktrees back
tractable.

**Plan location.** `docs/plans/<slug>-<date>.md`, as set out below - not the
`docs/superpowers/plans/` default in `writing-plans`. The plan index rule in the
next section applies to those files: append a pointer block, never rewrite one.

**Setup.** Where `using-git-worktrees` auto-detects a project and runs a bare
`npm install` or `pip install`, run `bash scripts/install-hooks.sh` instead. It
installs the dependencies *and* arms the gate and builds `.preflight-venv`; the
bare install leaves the hook able to run only the cheap checks.

**Integration.** `finishing-a-development-branch` presents a menu that includes
merging into the base branch and deleting the feature branch. Do neither by
hand - not that menu, not `git merge`, not `gh pr merge`. Integration happens,
but through `_auto-merge.yml` and only there; see **Integration** below for why
that distinction is the whole rule rather than a loophole in it.

**Pull requests.** `_auto-merge.yml` opens one for you when a `claude/**` or `ag/**` branch
passes the gate, so pushing the branch is normally the whole job. Opening one by
hand is for when you were asked in so many words, and then through the GitHub
MCP tools (`mcp__github__*`): a cloud session has no `gh` and no `hub`, so the
"forge's CLI" branch of that skill does not apply.

## Files parallel sessions must never share

Two sessions running at once will both edit the same index file and the merge
will conflict. This is structural, not bad luck.

| Kind       | Wrong                       | Right                                    |
|------------|-----------------------------|------------------------------------------|
| plan index | rewriting an existing block | APPEND your pointer block                |
| plan body  | the shared index            | its own `docs/plans/<slug>-<date>.md`    |
| journal    | editing in the middle       | append at top; `merge=union` handles it  |

`docs/journal.md` and `docs/plans/active-plan.md` are `merge=union`. What
enforces this is the `shared narrative files` stage of `preflight.sh`: it fails
the push when your branch has net-removed lines from one of them, because
appending is safe and rewriting is what turns a clean union into a duplicate.

Nothing checks the merged result afterwards, and that gap is real - union can
still interleave two blocks written against the same lines. The gate catches the
cause, not the symptom, which is why the rule above is APPEND rather than a
promise that a workflow will clean up after you.

## When CI goes red

Read the failing step and fix the cause. Do NOT open a pull request per
failure. Four open PRs in `DNB-MCP` all fixed the same container-name conflict,
none was merged, and each new red build spawned the next agent and the next PR
while the deploy kept failing. One diagnosis, one PR, merged.

## Secrets

Tokens go in an `Authorization` or `X-Deploy-Token` header, never in a URL path -
a path is written verbatim into the run log, which anyone with repository access
can read, and into the receiving service's own logs.

Never rotate or regenerate a credential on your own initiative. Report the
exposure and let the owner decide.

## Deploys

Deploy through the reusable workflow in `Bud-Fox/.github`, not a hand-rolled
`curl`. It fails fast on an empty secret, refuses an endpoint that is really an
MCP transport, retries transient upstream errors, and turns each status code
into a sentence that names the cause.

Any redeploy of a named container tears the old one down first:

```
docker compose down --remove-orphans && docker compose up -d --force-recreate
```

An `up` on top of a running container with a fixed name always conflicts.

## Scheduled workflows

A cron workflow is a recurring bill. State the monthly runner-minute cost in a
comment at the top of the file before adding one. A self-healing job that is a
no-op on most ticks alerts after N consecutive failures - it does not email on
every tick. 112 of the notifications in one 60-day window came from a single
hourly watchdog, and that volume is what hides the failures that matter.

## Integration

A branch that passes the gate and is never merged is work that does not exist.
Four of the five root causes behind the 159 failed runs stayed broken across
weeks because the fix sat on a branch nobody integrated.

So the rule is not "never merge". The rule is **who merges, and under what**:

| | |
|---|---|
| An agent merging by hand | **Never.** Not `git merge`, not `gh pr merge`, not the merge option in `finishing-a-development-branch`. A merge nobody can replay or audit is not a merge, it is an edit to `main` with extra steps. |
| `_auto-merge.yml` merging | **Yes**, and this is the only route. It is versioned, its gates are readable in one file, its refusals are written on the pull request, and it can be turned off by deleting one caller workflow. |

`.github/workflows/_auto-merge.yml` opens the pull request, and merges it only
when all of these hold. Each is a line in that file, not a convention:

- preflight is green - it is a `needs:` dependency, so a red gate skips the
  merge job rather than being checked and ignored
- the head branch starts with `claude/`
- the pull request is not a draft and carries no `hold` label
- it does not conflict with the base
- the diff touches none of the guarded paths - the workflows, the hooks,
  `preflight.sh`, `sync.sh`. **A gate that can rewrite its own rules
  unattended is not a gate**, so a change to the gate is always merged by hand.

Any guard that trips leaves the pull request open, labelled `needs-owner`, with
one comment naming the cause. One comment per cause, never one per push.

To stop a single branch, label its pull request `hold`. To stop a repository,
delete its `integrate.yml`; the gate in `ci.yml` keeps working without it.

A deploy runs in the same workflow run as the merge, chained with `needs:`,
because a push made with `GITHUB_TOKEN` does not start another workflow run - a
deploy waiting on `on: push: branches: [main]` would never fire, and the change
would reach `main` and stop there.

## Reporting

The end-of-task report follows `.claude/skills/reporting/SKILL.md`. Where it
disagrees with the report format in any vendored skill - `code-reviewer.md`,
`task-reviewer-prompt.md`, `re-review-prompt.md`, or a
`report-after-plan-completion` synced into the account - that file wins.

Three rules carry most of the value:

- **Five fixed sections, and an empty one is deleted rather than filled.** No
  material outside them: no preamble, no closing summary, no invented editorial
  heading over a finding.
- **A finding without a fix is deleted, not written.** Naming a problem and
  handing it back is not a report, it is work returned. If the cause is not yet
  established, the entry is one line: the symptom and the single next command
  that would establish it.
- **Every claim carries evidence from this session** - a command and its
  result, a count, a hash, a status code. Anything unverified says so and stays
  in the report.

## Deploy verification

**A deploy is not done when the endpoint returns 200. It is done when the
service reports the commit you asked for.**

Three separate things were all reporting success while production ran old code,
and each looked like confirmation:

| looked like proof | why it is not |
|---|---|
| `deploy.sh` exiting 0 | its last line was `curl health \| grep -q healthy && echo OK \|\| echo WARN`. `A && B \|\| C` is not if-then-else - the status is that of the last command, so the failure branch exits 0. `set -e` does not help: a failure consumed by `&&`/`\|\|` is exempt from `errexit`. |
| the webhook's `{"commit": "<sha>"}` | it echoes the SHA it was **sent**, never the one deployed. A client-side check against it passes always. |
| `_deploy-contabo.yml` seeing HTTP 200 | the host was free to ignore the SHA in the request body entirely, and did - `git reset --hard origin/main` takes whatever the tip is at that instant. |

So verification reads a **different URL** than the one it POSTed to, and
compares against a value the workflow already held rather than one the response
handed it. That separation is the whole mechanism; a check that trusts the
deploy response is decoration.

Two things that are easy to get wrong:

- **The SHA to verify is the merge commit, not the branch tip.** `_auto-merge.yml`
  squash-merges, so `github.sha` in the triggering run is the `claude/**` tip and
  `main` gets a different OID. It passes `merge_sha` explicitly, and when that
  OID cannot be read it refuses to deploy rather than falling back.
- **A verification that was already true before the deploy proves nothing.** The
  pre-deploy SHA is recorded first, and a match that was already there is
  announced as vacuous instead of green.

A service that exposes no build identity cannot be verified. Expose the deployed
commit on the health endpoint as `deployed_git_sha`; `DNB-MCP` is the worked
example.

## Clone ownership: BUD-LOCK

Before a subagent or preflight touches a clone, export a unique session identity
through all nested hooks, then acquire the lease:

```
export BUD_LOCK_OWNER="<task-id>:<unique-session-id>"
bash scripts/bud-lock.sh acquire
```

The lease is JSON with exactly `{"owner":"<session>","ts":<unix-seconds>,"ttl":3600}`.
`BUD_LOCK_TTL` overrides the default 3600 seconds and must be a positive integer.
The path is `git rev-parse --git-path BUD-LOCK`: `.git/BUD-LOCK` in a normal
clone, the linked worktree's private gitdir otherwise. Never commit it.
`HERMES_SESSION_ID` is the identity fallback; outside Hermes, the direct parent
process is the fallback, NOT a common daemon ancestor. Nested or parallel agents
must explicitly export their own `BUD_LOCK_OWNER`, not inherit another task's.
This is a named local write exception to the session-hook cache-only rule:
`bud-lock.sh` may write only the resolved gitdir lease, its temporary sibling,
and `BUD-LOCK.guard`; it makes no network calls.

Preflight acquires/refreshes this lease before checks; pre-push runs that same
preflight. It atomically borrows an existing same-owner lease, or acquires a
unique invocation identity known to the parent before acquisition. It releases
only its exact acquired identity on normal exit/failure/catchable cancellation;
a parent-owned lease and any replacement lease remain held. `acquire-scoped`
returns JSON `{owner,owned}`; `release-owned` never removes foreign state, even
when expired. SIGKILL cannot run cleanup and still requires TTL recovery.
The same owner refreshes `ts`. A fresh foreign owner is refused by
name with its remaining TTL, even if its PID appears dead. A corrupt lease fails
closed; inspect it rather than assuming the clone is free. At `now >= ts + ttl`
a foreign lease is expired: takeover logs `STALE LEASE TAKEN OVER`, previous
owner and age. Refresh before TTL expires on long tasks; release on handoff:
`bash scripts/bud-lock.sh release`. Explicit `release --force` is loud, not an
automatic recovery step; use only after establishing that takeover is safe.

Acquisition/release serialize through the atomic `BUD-LOCK.guard` mkdir; lease
writes use temp-file + rename. A busy/abandoned guard times out with a named
refusal, never silently deletes another updater's guard. Inspect its holder and
recover explicitly only after proving no update is in progress.

No process runs `pull --rebase`, `merge origin`, or `reset --hard` in a clone it
did not create and does not hold. Sync and sibling sessions must honor the same
lease before touching an existing clone. This hook is not a universal Git
interceptor: callers must acquire before other mutating commands too. Prefer an
owned clone when ownership is uncertain. Existing live sync wiring is rolled
out by the separate gh-sync hygiene task `t_8a0e799c`, not by claiming a policy
paragraph has already changed the running daemon.

## One owner of contract distribution

The single scheduled owner of `AGENT-CONTRACT.md` distribution is Contabo
`gh-sync.service`, `WorkingDirectory=/opt/gh-sync/src`,
`ExecStart=/opt/gh-sync/run.sh`. Read-only verification via `ssh gbbot-root` on
2026-10-21 confirmed `gh-sync.timer` has
`OnCalendar=*-*-* 03:17:00 UTC`, `Persistent=true`, `RandomizedDelaySec=120`.
The wrapper pulls `main` with `--ff-only` then calls `scripts/sync.sh`.
It replaces the hosted onboarding job; do not introduce a second scheduler.
Mac/manual sync runs require coordinated ownership plus the same lease, and must
not rewrite a clone held by another session. Runtime locking and schedule
coordination belong to `t_8a0e799c`; this change does not restart or modify the
host service.

### Runtime lease and schedule separation (t_8a0e799c, 2026-10-21)

Both host wrappers take the clone lease before touching git or GitHub:
`run.sh` as `gh-sync@<host>:sync[<pid>-<epoch>]`, `merge.sh` as
`gh-sync@<host>:merge[<pid>-<epoch>]` - unique PER PROCESS, because bud-lock
admits a same-owner acquire as a re-entrant refresh, and a constant
per-unit owner let two concurrent runs of one unit race (observed 2026-10-21:
two `git pull`s interleaved one FETCH_HEAD). Acquire is
`BUD_LOCK_OWNER=... BUD_LOCK_TTL=3600 scripts/bud-lock.sh acquire` on
`/opt/gh-sync/src`, released in an EXIT trap. A lease held by someone else
stops the run loudly, naming the holder - the two units (03:17 and 05:17 UTC)
and any manual invocation are thereby serialized against each other. There is
ONE fleet sync owner (the host timers). Mac-side or manual fleet runs must go
through `ssh gbbot-root /opt/gh-sync/run.sh ...` so the same lease covers
them; a local `sync.sh` against the whole fleet from a Mac clone is forbidden.
No Mac-side scheduled sync exists (crontab, LaunchAgents and hermes cron
checked 2026-10-21); if one is ever added it must not fire in the host window
05:17-07:17 CEST (03:17-05:17 UTC), because both sides write the same
deterministic branch name `sync/agent-contract-<sha>` and a race duplicates
branches, not work.

## One PR - one watcher

A watcher first checks for an unexpired owner comment on that exact PR. Use a
comment marker `BUD-PR-LEASE` followed by JSON `{owner, ts, ttl}` (Unix seconds,
default TTL 3600), with `owner` identifying a unique task/session. A label may
make the claim discoverable but does not encode ownership by itself.

Claim by posting the owner comment, then read back all lease comments before
starting work. If simultaneous claims exist, the oldest unexpired claim wins
(server `created_at`, then numeric comment ID breaks ties); losers stop. GitHub
comments are NOT an atomic mutex: read-back and conflict resolution are required,
and the watcher must recheck immediately before any PR-changing action.
Refresh the same comment before expiry, re-read to confirm, and explicitly mark
it released on handoff/completion. An expired-owner replacement names the old
owner and expiry in a loud takeover comment. No second duty subagent, duplicate
polling loop, or competing PR fix while a valid watcher owns the PR.
