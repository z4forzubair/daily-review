# Review instructions

Read by the daily-review and review-pr skills, in Claude Code and Codex. Keep it short: every line reaches every reviewer.

Base branch: main

## Who does what
- <Who writes the plan and the architecture docs. A commit that only changes them is design work, not developer code: the review asks that person what to do with it.>
- <Who writes the code, and from which documents.>
- <Who decides business or product rules.>
- <Optional: parts the review reports separately, e.g. "Report backend (`backend/`) and frontend (`frontend/`) findings in separate lists.">

## Sources of truth
Sources confirmed: yes

The review checks code against these files, read from this repository. List each path in backticks; `*` matches files in one folder. When a requirement changes, update the file.

- `<path to the plan, e.g. docs/plan.docx>`: the plan. It wins over everything below.
- `<path to architecture docs, e.g. docs/architecture/*.md>`: architecture and data model.
- `<path to task lists or requirements>`: what developers work from.

## Not sources
Planning files the review ignores.

- `<old plans and drafts>`

## Where we are
<Current phase or milestone, and what is intentionally not built yet.>

## Scale
Design for <expected scale, e.g. users, tenants, requests> within 12 months. Architecture comments judge growth against this.

## Severity here
Must fix also covers, for this project:
- <project-specific rule>

Minor: at most 5 per review.

## Always check
- <rule> (<plan section>)

Team defaults:
- Changed functions, endpoints and components have tests. Missing ones are listed under Missing tests; for auth, permissions and data writes they are Should fix.

## Do not report
- Formatting, lint and type errors (CI and pre-commit hooks catch them).
- Lockfiles, generated code, build output, binary files.

## Known decisions
Decisions that look wrong but are intended. One line each, with the date.
