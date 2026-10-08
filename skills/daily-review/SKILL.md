---
name: daily-review
description: End-of-day review of the developers' latest commits against the project's plan and architecture docs. Reports only the problems worth fixing (bugs, missed edge cases, plan deviations, missing tests, design that will not hold at the planned scale, decisions the plan has not made) as short PR-style comments, or one line when all is good, and tracks unfixed issues from day to day. With --architecture, reviews the whole system instead.
argument-hint: "[--architecture] [--days N | --since REF | --full | --rerun] [--base BRANCH] [what was built]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/scope.sh *)
  - Bash(git diff *)
  - Bash(git log *)
  - Bash(git show *)
  - Bash(git blame *)
  - Bash(git grep *)
  - Edit(.reviews/**)
---

# Daily review

## Scope
!`bash ${CLAUDE_SKILL_DIR}/scripts/scope.sh`

## Arguments
$ARGUMENTS

## What this is for
The user is the tech lead. The developers may use other tools, so they never see this session: the lead reads your review at the end of the day and forwards it to them. The lead wants two things from this skill: feedback that gets to the point instead of a long document, and the issues that matter for this project. Everything else is how you would normally work in a repository: understand the change before you judge it, read the code around it, and ask the lead when you need something only they know.

## Getting oriented
The Scope block lists the commits since the last review, the changed files, the diff file, the sources of truth and the previous review. If the arguments contain flags (`--days N`, `--since REF`, `--full`, `--rerun`, `--base BRANCH`, `--architecture`), run `bash ${CLAUDE_SKILL_DIR}/scripts/scope.sh` with those flags and use its output instead; any other words describe what was built. If the status is `nothing-new` or `error`, tell the lead in a line and stop.

Read `REVIEW.md` first. It says who does what on this project, which documents are the sources of truth, what stage the project is at and what matters most here. The decisions file, when there is one, lists what the lead has asked the review not to flag. Sources are files in this repository, so everyone works from the same version. Word files are converted to text for you (follow the `-> read` path), and a source listed under `specs_newer_on_base` should be read from the base branch. If there is no REVIEW.md, if it says `Sources confirmed: no`, or if the scope lists missing sources or `doc_candidates`, agree with the lead which documents to review against before anything else, and record it in REVIEW.md (start a new one from `${CLAUDE_SKILL_DIR}/templates/REVIEW.template.md`). Never keep a copy of a source outside the repository.

Then understand what was done: read the commit messages and the diff, the code around each change and what it calls, and the parts of the sources that cover this work. Work out which part of the plan or which task it implements, and whether it is developer work at all. A commit that only changes the plan or the architecture docs is the lead's own design work: ask what they want from the review rather than reviewing it like code.

Before you write the report, ask the lead (in one go) about anything you can't settle from the code and the docs that would change what you report: what the work is meant to do, whether a departure from the plan was agreed, whether something is in scope yet. Don't ask what REVIEW.md, the docs or the code already answer. A line or two telling the lead what you're reviewing and how is welcome.

## What to look for
What a strong senior engineer on this project would block or comment on in a pull request:
- Work that doesn't do what the plan or the task says for this feature, or contradicts it.
- Bugs and missed edge cases on reachable paths: empty, missing or unexpected input, errors swallowed or reported as success, half-finished writes, races and retries, dates and time zones.
- Security and privacy: role checks only in the UI, one customer's or tenant's data reachable by another, personal or secret data in logs, errors, URLs, analytics or browser storage.
- Changed behavior without tests, above all for auth, permissions, tenancy and data writes.
- Design that won't hold at the scale in REVIEW.md, with a rough estimate of why.
- Questions the plan doesn't answer that this work had to decide: recommend an answer and say who should decide (the developer, the lead or the client).
- Edits to the sources made in these commits: what changed, and anything it now conflicts with.

Leave out formatting, lint and type errors (hooks catch them), matters of taste, features the plan puts in a later phase, problems in code these commits didn't touch unless the new code depends on them, and anything REVIEW.md or the decisions file excludes.

For a large change you can hand parts of the reading to `daily-reviewer` subagents (by area, or by plan, correctness and design), passing on your understanding of the change and anything the lead told you. What they return are candidates; you decide what is real. Before you report, try to prove each finding wrong against the code, and when you have more than a couple of findings or any you're unsure about, have a `review-verifier` subagent check them with fresh eyes. A wrong finding costs the lead and the developer a round trip. When this skill comes from the daily-review plugin, the two subagents are named `daily-review:daily-reviewer` and `daily-review:review-verifier`.

## The report
Start with this line:

```
**Review** `<branch>` <base7>..<head7> · <n> commits · <m> files
```

When REVIEW.md splits the codebase into parts (for example backend and frontend), give each part its own heading (`## Backend`, `## Frontend`) with only its findings under it, so each developer gets a separate list. An item that needs changes in more than one part goes under the part where the problem starts and says what the other part must change. Leave out a part these commits didn't touch; for a part they touched with nothing to report, write `All good.` under its heading. Without parts, the sections follow the first line directly.

Within each part, these sections in this order, leaving out empty ones:
- **Must fix**: breaks behavior on a reachable path, a security or privacy hole, data loss, or contradicts the plan for this feature.
- **Should fix**: a real problem that is less likely or less costly.
- **Missing tests**: one line per file, naming what isn't tested and the cases.
- **Minor**: harmless today but worth fixing; five at most.
- **Still open** from earlier reviews: one line each, with the number, the date first flagged, the location and a short title.

After the parts, the sections about the change as a whole:
- **Decisions needed**: what the plan doesn't settle, each starting with who decides: [developer], [lead] or [client]. Problems in the plan or the architecture docs themselves go here too, as [lead] items.
- **Spec changed** in this range: one line per source.

Numbers run across the whole report, so each number means one item. Then, when they apply: `Open decisions: #n (date, owner)`, `Tests still missing: <path> (<count>)` and `Fixed since <date>: #n, #n`. When there is nothing to report at all, the whole report is one line: ``All good. `<branch>` <base7>..<head7>, <n> commits.``

Write each finding so a junior developer can act on it without opening the plan: a bold headline saying what goes wrong and for whom, then why in plain words, naming the variables, functions or columns involved where that helps, then the fix, then the location and plan section. Keep it as short as that allows, with no praise and no description of code that is fine. For example:

```
16. **A discount code larger than the order makes the total negative, and checkout refunds the customer.** `apply_discount` subtracts `code.amount` from `order.total` with no floor, so a $20 code on a $15 order saves `total = -5`, and the payment step treats it as a $5 refund. This commit added fixed-amount codes but kept the arithmetic written for percentage codes.
    Fix: use `max(order.total - code.amount, 0)` and reject the code when it exceeds the order. (`api/orders/discounts.py:58`, plan 4.2)

17. [lead] **Nothing says what happens to a team's projects when the owner deletes their account.** This commit adds account deletion, and `delete_user` leaves the owner's projects with `owner_id = NULL`, which the dashboard query skips, so the rest of the team loses access to them. The plan covers deleting an account but not handing projects over.
    Recommend: block deleting an owner who still has projects until ownership is transferred, and add a transfer endpoint. Update plan 6.3 once decided.
```

Numbers identify items across days: continue from the highest number in the previous review, and carried-over items keep theirs. If there is a previous review, check each of its open items against the current code (yourself or through the `review-verifier`): fixed, still open, or gone with the code. Decisions stay open until the docs cover them or the lead drops them; Minor and Spec changed items don't carry over.

Save the report to `log_file`: the `log_frontmatter` lines exactly as printed, a blank line, then the report. Don't repeat the report in the conversation: tell the lead where you saved it, with one line of counts per part (for example "Backend: 2 must fix, 5 should fix. Frontend: 1 should fix. 1 decision"), plus anything you need from them. An All good review is still saved.

## Weekly architecture review (`--architecture`)
Review the whole system at HEAD instead of a diff: request handling and auth, the data model and migrations, background jobs, integrations, and audit and telemetry writes, against the roadmap in the sources and the scale in REVIEW.md. Report only the few design decisions that won't hold at that scale or will block the next phases, most important first, each with a rough estimate, what argues against changing it, and a recommendation. Start with ``**Architecture review** `<branch>` <head7>``, and when there is an earlier architecture review, end with `Still open from <date>: #n` and `Resolved since <date>: #n`. A `daily-reviewer` given the whole-system brief can do the reading. Save it to the `log_file` this scope gives and, as for daily reviews, tell the lead where it is instead of repeating it.

## After the report
- When the lead says a finding is intended or wrong ("#3 is fine", "don't flag X"), add one line to `.reviews/decisions.md`: `- <date> <path or area>: <what not to flag> (<reason>)`. If it applies to the whole team, suggest adding it to REVIEW.md under Known decisions.
- "Message for the developer": rewrite the findings as a message to the developer in plain words, without em-dashes; one message per part when the report has parts.
- Don't change the project's code unless the lead asks.

## Files
`.reviews/` is kept out of git (`.git/info/exclude`): one file per review in `.reviews/<branch>/`, named `review-<n>-<date>_<HHMM>.md`, architecture reviews in `.reviews/architecture/`, `decisions.md`, and scratch files in `.work/`. `scripts/scope.sh` picks the commit range, writes the diff and converts Word sources to text with `scripts/docx2md.py`.
