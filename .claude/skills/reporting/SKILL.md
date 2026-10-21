---
name: reporting
description: >
  The shape of the message an agent writes when a task ends. Use at the end of
  any task, plan, or session that produced changes - and instead of the report
  format in report-after-plan-completion, code-reviewer.md, task-reviewer-prompt.md
  or re-review-prompt.md wherever the two disagree. This file wins.
---

# The end-of-task report

The report is the only part of a session the owner actually reads. Its job is
to let them decide what to do next in under a minute. Everything that does not
serve that decision is cost.

## The single structure

The report is these sections, in this order, and nothing else. No preamble, no
closing summary, no material outside them.

```
## Result
## Changed
## Not done
## Found while working
## Decision needed
```

**An empty section is deleted, not filled.** A report with only `## Result`
and `## Changed` is a good report, not a lazy one. Never write "none", "n/a",
or "this section is empty" - deleting the heading says it better.

### `## Result` - one to three lines

What works now that did not before, or what is still broken. State it as a
fact with the evidence attached.

> Auto-merge workflow added; `claude/**` branches now merge and deploy on a
> green gate. Validated: 4 run blocks parse, 6 workflow files load.

Not `I have successfully implemented...`, not a recap of the request.

### `## Changed` - one row per file or coherent group

| what | why | evidence |
|------|-----|----------|

`evidence` is a command and its result, a count, a hash, or a status code.
Never an adjective. `18/18 pytest passing` is evidence; `tests look good` is
not. If a change is unverified, the row says `unverified` - that is a fact,
and hiding it is the only real failure here.

### `## Not done` - what was in scope and is not there

One row each: the item, why, and what it would take. Something the owner asked
for and did not get is the highest-value line in the report; it goes here in
full, never softened and never left out because the rest went well.

### `## Found while working` - at most three, each with its fix

This section exists because a real defect noticed in passing is worth
reporting. It is capped and disciplined because an uncapped one turns every
report into an essay about whatever the session happened to look at.

Each entry is at most two lines and carries all four of:

1. the symptom, concretely - file, line, or the command that shows it
2. the cause, in one clause
3. **the fix** - the actual change, specific enough to act on
4. **where it goes** - `fixed here` / `needs its own branch` / `owner's call: <the one question>`

**An entry without a fix is deleted, not written.** "This is worth thinking
about", "worth checking whether this still applies", "I noticed X is odd" -
these hand the owner work instead of doing it. If the fix is not yet known,
the entry is one line: the symptom, and `cause not established - <the single
next command that would establish it>`.

Nothing outside the session's tasks reaches the report by any other route. If
it did not fit here, it did not belong in the report.

### `## Decision needed` - at most one, only if it blocks

One question, with the options and a recommendation. Present only when work
genuinely cannot continue without the answer.

> Merge PR #1 (vendors the skills) before or after this branch? Recommend
> before: this branch's contract edits append cleanly on top of it.

If nothing is blocked, delete the section. An open question at the end of a
report is not politeness - it is unfinished work handed back.

## Register

Write like an engineer writing to another engineer who is busy.

- Numbers instead of adjectives. `227 lines`, `HTTP 409`, `0 runs`, `3 of 8
  repositories`. Never `significantly`, `robust`, `comprehensive`.
- Own mistakes stated flatly in one sentence, then move on. No self-criticism,
  no apology, no account of how it felt to find them.
- Report in the language the owner wrote in.
- Section headings are the five above, used verbatim. Never invent an editorial
  headline for a section - `## Found while working` never becomes
  `## Two findings worth more than the fixes themselves`. A headline that
  editorialises is an argument for the finding's importance, and the finding
  should not need one.
- No aphorisms, no framing sentences, no drum roll before a fact. Cut every
  sentence whose removal loses no information.
- Do not narrate process: which skill was loaded, which tool was called, what
  was considered and rejected. The diff and the tool results are the record.
- Do not restate the diff in prose. The `## Changed` table is the diff's summary.

## Length

Forty lines for an ordinary task, including tables. A large multi-day branch
may run to eighty. Past that, the detail belongs in a file the report links to,
and the report says where it is in one line.

## Before sending

Two checks, both fast:

1. **Every claim in `## Result` and `## Changed` has evidence in the row.**
   Not remembered evidence - a command run in this session. Anything you have
   not verified says `unverified` and stays in the report.
2. **Every entry in `## Found while working` names a fix and a disposition.**
   Delete the ones that do not.
