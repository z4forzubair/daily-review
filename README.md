# daily-review

Code review for tech leads who review their team's work every day, and their pull requests. Works in **Claude Code**, **Codex** and **Cursor**.

Run `/daily-review` (`$daily-review` in Codex) at the end of the day. It reviews the commits pushed since your last review against your project's plan, specs and architecture docs, and reports only what is worth fixing:

- bugs and missed edge cases
- work that doesn't match the plan or the task
- missing tests
- design that won't hold at the scale you plan for
- decisions the plan hasn't made yet, and who should make them

The report is short and written like pull-request comments, with a separate list for each part of the codebase (for example backend and frontend). When nothing needs fixing, it's one line. Unfixed items carry over to the next day's review until they're fixed.

Run `/review-pr` (`$review-pr` in Codex) with a pull request's link to review it the same way and post the findings on the PR as a pending GitHub review, which you check and submit.

All three use the same `REVIEW.md` and the same `.reviews/` folder, so you can switch between them on one repository and keep the numbering and open items.

## Install

### Claude Code

```
/plugin marketplace add z4forzubair/daily-review
/plugin install daily-review@daily-review
```

Then run `/reload-plugins` or start a new session.

### Codex

As a plugin:

```
codex plugin marketplace add z4forzubair/daily-review
```

Then open `/plugins` in Codex, install **daily-review**, and start a new session.

Or as skills, which any Codex version with skills support can load:

```
git clone https://github.com/z4forzubair/daily-review ~/.daily-review
mkdir -p ~/.agents/skills
ln -s ~/.daily-review/codex/skills/daily-review ~/.agents/skills/daily-review
ln -s ~/.daily-review/codex/skills/review-pr ~/.agents/skills/review-pr
```

Update them later with `git -C ~/.daily-review pull`.

In Codex, type `$daily-review` or `$review-pr <PR link>`, or pick them from `/skills`. Codex keeps commands in a sandbox without network access, so it asks you to approve the steps that fetch the PR, post the review, or write to `.git`. The review itself runs inside the sandbox.

### Cursor

As a plugin: in Cursor, open **Customize**, choose **From GitHub Repository**, enter `z4forzubair/daily-review`, and install **daily-review**. That adds the two skills and the two read-only reviewer subagents.

Or as skills and subagents:

```
git clone https://github.com/z4forzubair/daily-review ~/.daily-review
mkdir -p ~/.cursor/skills ~/.cursor/agents
ln -s ~/.daily-review/cursor/skills/daily-review ~/.cursor/skills/daily-review
ln -s ~/.daily-review/cursor/skills/review-pr ~/.cursor/skills/review-pr
ln -s ~/.daily-review/cursor/agents/daily-reviewer.md ~/.cursor/agents/daily-reviewer.md
ln -s ~/.daily-review/cursor/agents/review-verifier.md ~/.cursor/agents/review-verifier.md
```

Skip the `git clone` if you already cloned the repository for Codex. Cursor also loads skills from `~/.agents/skills`, so if you linked the Codex skills there, Cursor shows each skill twice: install it as a plugin in one of the two.

In Cursor's Agent chat, type `/daily-review` or `/review-pr <PR link>`. Cursor runs commands in its sandbox where it can; the steps that fetch the PR and post the review call GitHub, so they may need to run outside it, and Cursor asks you when it needs to.

**Requirements:** git and bash. Python 3 reads Word (`.docx`) docs and, for pull requests, GitHub's replies. Pull-request reviews also need the [GitHub CLI](https://cli.github.com), logged in with `gh auth login`. Tested on macOS and Linux; Windows is untested (use Git Bash or WSL).

## First run

Run `/daily-review` in a git repository (`$daily-review` in Codex). In Claude Code, if another command already uses that name, run `/daily-review:daily-review`.

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

## Review a pull request

Run `/review-pr` (`$review-pr` in Codex) from your clone of the repository, with the PR's link or number:

```
/review-pr https://github.com/acme/shop/pull/42
```

In Claude Code, if another command already uses that name, run `/daily-review:review-pr`.

It reviews the PR exactly as `/daily-review` reviews a day's commits, against the same `REVIEW.md` and docs, and saves the same report. Then it posts the findings on the PR as a **pending review**: inline comments on the lines they are about, with a one-click suggested change where the fix is small, and a summary for the rest. Nobody else sees a pending review. Open the PR's Files changed tab, read the comments, edit or delete any you disagree with, and submit the review yourself (Comment, Approve or Request changes). The plugin never submits, approves or requests changes for you.

- **Your work stays as it is.** The PR is checked out in its own git worktree inside your repository's `.git` folder (`.git/review-pr/pr-<n>`), so your branch, staged files and uncommitted changes are never touched, and your test runners, linters and editor don't pick up the PR's files.
- **It never runs the PR's code.** It reads the code and its history; the PR's tests, build scripts and git hooks don't run on your machine.
- **A PR can't change the rules it is reviewed against.** `REVIEW.md` is read from the PR's base branch (or from your checkout when you are on that branch), never from the PR.
- **It knows the context.** The PR description is taken as the developer's stated intent, and points other reviewers have already made are not repeated.
- **Run it again after new commits** and it reviews only what changed since its last review of that PR, and lists what is still open and what was fixed.

| Option | What it does |
| --- | --- |
| `--dry-run` | Write the review and its GitHub version, but post nothing |
| `--full` | Review the whole PR again, ignoring earlier reviews of it |
| `--rerun` | Review the same range as the last review of this PR |
| `--clean` | Remove the PR's worktree (with no PR given, every PR's); the reports stay |

The report is saved to `.reviews/pr-<n>/review-<n>-<date>_<time>.md`, and what goes to GitHub next to it, ending in `.github.md`. To change a posted review, ask for the change and say to replace the pending review; it deletes your pending review on that PR and posts the new one. When you're done with a PR, `/review-pr 42 --clean` removes its worktree.

## How it works

- `scripts/scope.sh` picks the commits since the last review, writes the diff and converts Word documents to text.
- The agent reads the change, asks you when something only you can answer would change the verdict, and writes the review.
- For large changes it can hand parts of the reading to a read-only `daily-reviewer` subagent, and a `review-verifier` subagent re-checks findings against the code with fresh eyes before you see them. The Claude Code and Cursor plugins ship both subagents (on Opus in Claude Code; on your chosen model in Cursor), and in Codex the skill spawns them from instructions in the skill.
- For a pull request, `skills/review-pr/scripts/pr.sh` fetches the PR with `gh` and `git`, checks it out in a worktree and runs `scope.sh` there. `post_review.py` places each comment on the PR's diff and creates the pending review through `gh api`.
- The Claude Code plugin in `skills/` and `agents/` is the source. `tools/build.py` builds the Codex plugin in `codex/` and the Cursor plugin in `cursor/` from it: the same scripts and the same review guidance word for word, with the Claude-only parts (commands run when a skill loads, plugin subagents) rewritten for each agent.

## Cost

A small day's changes took about 200K tokens in testing. Large ranges, the first review of a long branch, and large pull requests cost more.

## License

MIT
