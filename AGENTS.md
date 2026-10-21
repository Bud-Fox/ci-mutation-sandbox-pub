# Agent entry point - Bud-Fox

Read this first. It is short on purpose; it points at the two things that are
long.

## Before you push

`AGENT-CONTRACT.md` is binding. Run `bash scripts/install-hooks.sh` in a fresh
clone or container before anything else - it arms the `pre-push` gate and builds
the cached venv the gate needs.

## While you work

Commit at every completed unit of work, and stage an explicit pathspec - never
`git add -A`, `-u`, `.`, or `git commit -a`. Frequent commits bound what a dead
session or a dead subagent can take with it; a named pathspec means a crashed
subagent's half-edit, a scratch file, or deliberately corrupted source cannot
ride in behind a commit you thought was yours.

Be clear about which half is guaranteed: a `PreToolUse` hook denies the blind
staging forms and no permission mode gets around it, but **nothing enforces the
frequency** - no hook event means "a unit of work finished" - so that half is
discipline. `## Commits` in `AGENT-CONTRACT.md` has the reasoning.

## Before you start the work

`.claude/skills/` is checked into this repository and loads automatically in any
session, cloud or local. Match the task against the `description` line of each
skill and read the one that fits before you begin - the skills are the process,
not documentation about it.

| When the task is | Use |
|------------------|-----|
| a spec or a multi-step request, before any code | `writing-plans` |
| a written plan, tasks independent, this session | `subagent-driven-development` |
| a written plan, executed in a session of its own | `executing-plans` |
| any feature or bugfix, before the implementation | `test-driven-development` |
| a bug, a red test, or behaviour you cannot explain | `systematic-debugging` |
| about to call something done, fixed, or passing | `verification-before-completion` |

The skills were written for a laptop. Where they assume one, our defaults are
declared under **Declared preferences** in `AGENT-CONTRACT.md`, and they bind:
no worktree and no consent question by default (a cloud session is already an
isolated container), the one exception being that **dispatching more than one
writing subagent at a time gets each of them a native worktree**, which
overrides `subagent-driven-development`'s blanket ban on parallel implementers -
that ban's stated reason is the conflict, and a worktree each removes it; plans
in `docs/plans/<slug>-<date>.md`; setup through `scripts/install-hooks.sh`; and
never merge or delete a branch by hand.

That last one is not "never integrate". Push a `claude/**` branch and
`.github/workflows/integrate.yml` runs the gate, opens the pull request and
merges it once the gate is green and no guard trips - the whole point is that
you do not have to remember. It deploys too, in the repositories that have set
`deploy-endpoint` in that file; where it is unset the chain stops at the merge
and says so. What is forbidden is doing it yourself, because a merge nobody can
replay or audit is an edit to `main` with extra steps. `## Integration` in
`AGENT-CONTRACT.md` lists every guard that stops it.

`.claude/skills/README.md` covers where they come from, what was changed in
them, and how to refresh. Do not edit a skill file - it is vendored and gets
overwritten without a diff to notice.
