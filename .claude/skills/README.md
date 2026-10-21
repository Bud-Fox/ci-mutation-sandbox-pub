# Vendored agent skills

Source: [`obra/superpowers`](https://github.com/obra/superpowers), copied by
`scripts/vendor-skills.sh`. Integrity is pinned in `MANIFEST.sha256`.

## Why they are checked in rather than installed

A cloud session gets a fresh container and a fresh clone, with no plugin state
and no marketplace step. Anything an agent needs at minute one has to arrive in
the clone. Committing the skills makes a web session, a GitHub Action and a
local terminal load the identical set - the same reason `preflight.sh` is one
file rather than a workflow and a hook that drift apart.

## How a skill gets invoked

Each `SKILL.md` opens with `name` and `description` frontmatter. The
description is the trigger - `systematic-debugging` reads "Use when
encountering any bug, test failure, or unexpected behavior, before proposing
fixes" - so an agent matches the task at hand against those descriptions and
loads the body of the one that fits. Nothing has to be typed by hand. The
routing table in `AGENT-CONTRACT.md` states the cases we care about explicitly,
for the times the match is not obvious.

## What was changed, and what was not

These files carry no hooks. There is no `settings.json`, no `SessionStart` or
`PreToolUse` handler, no executable, and nothing but markdown in the tree -
they are read by an agent, they never run. Upstream's plugin ships hooks; this
is the `skills/` subtree only, which is why none came along.

One transformation is applied, by the vendoring script and nowhere else.
Upstream writes cross-references plugin-qualified, as
`superpowers:using-git-worktrees`. These skills are installed unqualified, so
that name resolves to nothing and the handoff dies mid-task. The prefix is
stripped. `MANIFEST.sha256` records both the bytes as served (`[upstream]`) and
the result (`[local]`), so a refresh can tell upstream drift from a hand-edit.

The five entry points are `writing-plans`, `executing-plans`,
`subagent-driven-development`, `systematic-debugging` and
`test-driven-development`. The other four are here because those five hand off
to them, and a handoff to a missing skill is a dead end mid-task.

One known dangling pointer survives: `executing-plans` links
`../using-superpowers/references/`, outside this closure. It sits in an advisory
note about subagent availability, and the note's conclusion - prefer
`subagent-driven-development` where subagents exist - is what holds in a Claude
Code session, where they do. Nothing dereferences the link.

Where a skill's default conflicts with how this account works - the worktree
consent prompt, the plan directory - the override is declared under **Declared
preferences** in `AGENT-CONTRACT.md`. The skills defer to preferences stated in
your instructions, so that is a supported extension point, not a patch.

## Scope: where these are actually available

Three scopes load skills, and they are not interchangeable.

| Scope | Reaches | Fed from |
|-------|---------|----------|
| repo `.claude/skills/` | sessions opened on **that repo** | this repo, via `scripts/sync.sh` |
| account sync | **every** project and session | claude.ai settings, not git |
| container `~/.claude/` | the current session only | rebuilt per session - nothing persists |

Checking the skills in covers the first row, which is why `sync.sh` exists. It
does not cover a repo nobody synced, and it cannot cover the third row, because
a cloud container's home directory is discarded when the session ends.

For the second row - the only one that means "available by default everywhere" -
the skills have to be uploaded as account skills at claude.ai. Run
`scripts/package-skills-for-upload.sh` to get one zip per skill for that form.
Doing so makes the repo copies redundant but not wrong: a repo that carries them
still works for anyone whose account does not.

## Changing them

Do not edit these files. `scripts/vendor-skills.sh` overwrites the whole tree
and your change disappears on the next refresh, silently.

```
bash scripts/vendor-skills.sh           # refresh from upstream
bash scripts/vendor-skills.sh --check   # fail on upstream drift or a local edit
```

`--check` reports those two failures separately and names the file. It is
deliberately not part of `preflight.sh`: that gate must fail on what the author
changed and never on the state of the machine, and a check that needs the
network to pass breaks exactly that property.
