---
name: review-pr
description: Reviews a GitHub pull request the way /daily-review reviews a day's commits, against the project's plan and REVIEW.md, then posts the findings on the PR as a pending review with inline comments, which the lead checks and submits on GitHub. Takes the PR's link or number.
argument-hint: "<PR link or number> [--dry-run] [--rerun | --full | --clean] [what was built]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/guide.sh *)
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pr.sh *)
  - Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/post_review.py --dry-run *)
  - Bash(git diff *)
  - Bash(git log *)
  - Bash(git show *)
  - Bash(git blame *)
  - Bash(git grep *)
  - Edit(.reviews/**)
---

# Review a pull request

## Arguments
$ARGUMENTS

## What changes for a pull request
Review the pull request exactly as /daily-review reviews a day's commits: the purpose, what to look for, the report and the follow-ups are daily-review's, included at the end. Two things change: the PR's code is checked out in a worktree of its own, and the findings also go on the PR as a pending review, which only the lead sees until they submit it on GitHub.

**Fetch the PR.** Run `bash ${CLAUDE_SKILL_DIR}/scripts/pr.sh "<PR link or number>"`, adding any `--rerun`, `--full`, `--clean`, `--since REF` or `--days N` from the arguments. It checks the PR out in a worktree inside the lead's checkout without touching their branch, then prints the PR's details and daily-review's scope for it. With `--clean`, pr.sh only removes PR worktrees (the logs stay): tell the lead what it removed and stop. If it reports `status: error`, tell the lead in a line and stop. If the scope says `nothing-new`, tell the lead, and if `previous_draft` was never posted, offer to post it.

**Review it as daily-review does**, with these differences:
- The scope comes from pr.sh. Where daily-review says to run scope.sh with flags, run pr.sh with them instead.
- The PR's code is in `worktree`. Read, search and list files there: the lead's own checkout is on another branch, and a search of the whole checkout skips the worktree. For git, name the commits from the scope rather than relying on HEAD: `git show <head>:<path>`, `git blame <head> -- <path>`, `git grep <pattern> <head>`. Never run the PR's code, tests or build scripts: a pull request can carry code that shouldn't run on the lead's machine, above all one from a fork. Brief any subagent the same way.
- `description` holds the PR's title and description: the developer's account of what the PR does and why. Use it as the stated intent and check it against the code. `checks` gives the CI results for the PR's head: evidence about the code (for example, whether the tests pass), not findings to repeat, since the developer sees them on GitHub.
- `existing_comments` holds what others have already said on the PR. The report covers every finding, but on GitHub don't repeat a point someone has made: when it is still unresolved at the PR's head, add only what they missed, and say whose point you are building on.
- REVIEW.md is the file named in the scope's `review_md`, chosen so that a PR can't change the rules it is reviewed against. If the PR edits REVIEW.md, report the edit as a [lead] decision. If there is no REVIEW.md, or its sources aren't confirmed, settle them with the lead as daily-review says and keep REVIEW.md in the lead's own checkout (the folder that holds `.reviews/`), never in the worktree.
- `branch_review`, when pr.sh prints it, is the lead's last /daily-review of the PR's branch, from before this PR's first review. Treat it as the previous review for numbering and open items, while still reviewing the whole PR.
- `--architecture` belongs to /daily-review only.

**Write the GitHub draft** to `github_draft` after saving the report. It is what the developer will read on the PR:

```
# Summary
<the review's opening comment>

# Comments
## <path>:<line>
<an inline comment>

## <path>:<first line>-<last line>
<a comment on several lines>
```

- A finding or a [developer] decision about particular lines of the PR's diff becomes an inline comment on those lines. `commentable_lines` lists the lines GitHub accepts comments on; lines marked + are the ones the PR adds or changes. Start the comment with `**#<n> · Must fix · <headline>**` (or Should fix, Minor, Decision), then the explanation and the fix as in the report, without the location, which GitHub shows.
- When the fix is a small, exact replacement, add it as a `suggestion` code block, which the developer can apply with one click. It replaces exactly the commented lines, so the heading's line range must match the lines it replaces, indentation included.
- Everything else goes in the summary, numbered and labelled the same way: missing tests, problems that span files or sit outside the diff, and [developer] decisions not tied to a line. Open the summary with what has to change before the PR can merge, in a line or two, without repeating the inline comments. Items still open from an earlier review of this PR were posted then: list their numbers in one line, with a few words where only part was fixed, and the numbers fixed since. Items carried over from `branch_review` have never been on GitHub, so post them like new findings. When there is nothing to report, one line saying so is enough; approving is the lead's call.
- Leave out what is only for the lead: [lead] and [client] decisions, notes about the plan, Spec changed. If the PR has to wait for one of those decisions, say that it waits on a decision about it.
- Write to the developer in plain words, without praise or em-dashes.

**Post it.** Check the draft with `python3 ${CLAUDE_SKILL_DIR}/scripts/post_review.py --dry-run <github_draft>`. It lists comments it had to shrink to the diff or move to the summary: correct any line you got wrong, and leave a comment in the summary when its problem really is outside the diff. When the arguments include `--dry-run`, stop there and tell the lead where the draft is. Otherwise post with `python3 ${CLAUDE_SKILL_DIR}/scripts/post_review.py <github_draft>`. It creates a pending review and never submits, approves or requests changes.

Then tell the lead, in a few lines, where the report is saved with daily-review's counts per part, what went to GitHub, and what you need from them. For example: "Saved the review to `.reviews/pr-42/review-1-2026-10-29_1830.md`. Backend: 2 must fix, 1 minor; 2 decisions for you. Posted a pending review with 3 inline comments and 2 items in the summary: <link>. Only you can see it until you submit it from the PR's Files changed tab." Mention anything the script moved, shrank or warned about. If the script says they already have a pending review on this PR, tell them, and use `--replace-pending` only when they ask for it: it deletes that pending review, including any comments they added to it on GitHub.

## After posting
- To change a posted review, edit the draft and post again with `--replace-pending`, once the lead confirms their pending review holds nothing they want to keep. They can also edit or delete the comments on GitHub before submitting.
- When the lead is done with the PR, `bash ${CLAUDE_SKILL_DIR}/scripts/pr.sh --clean <number>` removes its worktree (without a number, every PR's). The review logs stay in `.reviews/pr-<number>/`.
- daily-review's follow-ups below apply as well.

# From /daily-review

!`bash ${CLAUDE_SKILL_DIR}/scripts/guide.sh`
