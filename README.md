# daily-review

A Claude Code plugin for tech leads who review their team's work every day.

Run `/daily-review` at the end of the day. It reviews the commits pushed since your last review against your project's plan, specs and architecture docs, and reports only what is worth fixing:

- bugs and missed edge cases
- work that doesn't match the plan or the task
- missing tests
- design that won't hold at the scale you plan for
- decisions the plan hasn't made yet, and who should make them

The report is short and written like pull-request comments, with a separate list for each part of the codebase (for example backend and frontend). When nothing needs fixing, it's one line. Unfixed items carry over to the next day's review until they're fixed.

## Install

In Claude Code:

```
/plugin marketplace add z4forzubair/daily-review
/plugin install daily-review@daily-review
```

Then run `/reload-plugins` or start a new session.

**Requirements:** git and bash. Python 3 is used only to read Word (`.docx`) docs. Tested on macOS and Linux; Windows is untested (use Git Bash or WSL).

## First run

Run `/daily-review` in a git repository. If another command already uses that name, run `/daily-review:daily-review`.

On the first run it looks for plan, spec and architecture documents, asks you which ones to review against, and creates `REVIEW.md` at the repository root. Commit that file, so everyone reviews against the same documents.

`REVIEW.md` is where you describe your project in a few lines:

- who writes what (for example, your own design docs are reviewed differently from developer code)
- the sources of truth and the files to ignore
- the current stage, so it doesn't ask for features planned for later
- the scale to design for
- what counts as "must fix" in your project, and what not to report

## Options

| Option | What it reviews |
| --- | --- |
| *(none)* | Commits since the last review |
| `--days N` | Commits from the last N days |
| `--since REF` | Commits since a commit or branch |
| `--full` | The whole branch, ignoring earlier reviews |
| `--rerun` | The same range as the last review |
| `--base BRANCH` | Compare against a base branch other than the one in `REVIEW.md` |
| `--architecture` | The whole system, for a weekly design review |

Any other words are treated as context about what was built, for example `/daily-review finished the invoice export`.

## What you get

Each review is saved to `.reviews/<branch>/review-<n>-<date>_<time>.md`, and the conversation shows a one-line summary. The `.reviews/` folder stays out of git automatically.

A finding looks like this:

```
16. **A discount code larger than the order makes the total negative, and checkout refunds the customer.** `apply_discount` subtracts `code.amount` from `order.total` with no floor, so a $20 code on a $15 order saves `total = -5`, and the payment step treats it as a $5 refund.
    Fix: use `max(order.total - code.amount, 0)` and reject the code when it exceeds the order. (`api/orders/discounts.py:58`, plan 4.2)
```

After a review you can say:

- "#3 is fine" or "don't flag X": it records the decision and stops flagging it.
- "Explain #2": it explains the finding with the code lines.
- "Message for the developer": it rewrites the findings as a message you can send.

## How it works

- `scripts/scope.sh` picks the commits since the last review, writes the diff and converts Word documents to text.
- Claude reads the change, asks you when something only you can answer would change the verdict, and writes the review.
- For large changes it can hand parts of the reading to the `daily-reviewer` agent. The `review-verifier` agent re-checks findings against the code with fresh eyes before you see them. Both are read-only and run on Opus.

## Cost

A small day's changes took about 200K tokens in testing. Large ranges, and the first review of a long branch, cost more.

## License

MIT
