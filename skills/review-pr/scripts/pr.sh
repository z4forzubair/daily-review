#!/usr/bin/env bash
# review-pr: fetch a GitHub pull request into its own worktree and print the review scope.
#
# Usage:
#   pr.sh <PR link | number | branch> [--rerun | --full | --since REF | --days N]
#   pr.sh --clean [<PR link | number>]    remove PR worktrees; review logs are kept
#
# The PR is checked out, detached, in a git worktree at .git/review-pr/pr-<n>, inside your
# repository's .git folder, where test runners, linters, IDEs and searches don't pick it up.
# Your branch, index and uncommitted changes are never touched. daily-review's scope.sh
# then runs inside that worktree, with the review logs in .reviews/pr-<n>/.
# The PR details that post_review.py needs are saved in .reviews/.work/pr-<n>/pr.json.
#
# Needs git, the GitHub CLI (gh, logged in) and python3. Always exits 0 and reports
# problems as "status: error". Written for macOS /bin/bash 3.2 and BSD tools.

export GIT_OPTIONAL_LOCKS=0
# The review worktree never downloads Git LFS files.
export GIT_LFS_SKIP_SMUDGE=1
out() { printf '%s\n' "$*"; }
fail() { out "status: error"; out "error: $*"; exit 0; }
WARN=""
add_warn() { WARN="${WARN}  - $*
"; }

HERE=$(cd "$(dirname "$0")" && pwd)
SCOPE="$HERE/../../daily-review/scripts/scope.sh"
POST="$HERE/post_review.py"

PR_ARG=""; CLEAN=0; PASS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --rerun|--full) PASS="$PASS $1"; shift ;;
    --since|--days) if [ $# -ge 2 ]; then PASS="$PASS $1 $2"; shift 2; else shift; fi ;;
    --since=*|--days=*) PASS="$PASS $1"; shift ;;
    -*) shift ;;
    *) [ -z "$PR_ARG" ] && PR_ARG="$1"; shift ;;
  esac
done

command -v git >/dev/null 2>&1 || fail "git is not installed"
git rev-parse --show-toplevel >/dev/null 2>&1 || fail "not inside a git repository; run /review-pr from your clone of the PR's repository"
# Your own checkout, even when this runs from inside a PR worktree.
MAIN=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$MAIN" ] && [ -d "$MAIN" ] || MAIN=$(git rev-parse --show-toplevel)
cd "$MAIN" || fail "cannot open $MAIN"
REV="$MAIN/.reviews"
# PR worktrees live in the repository's .git folder, which every tool skips, so a test
# runner or linter run in your checkout never picks up a PR's files.
GITCOMMON=$(git rev-parse --git-common-dir 2>/dev/null)
case "$GITCOMMON" in /*) ;; ?*) GITCOMMON="$MAIN/$GITCOMMON" ;; esac
case "$GITCOMMON" in
  "$MAIN"/*) TREES="$GITCOMMON/review-pr" ;;
  *) TREES="$REV/trees" ;;   # the git folder is outside this checkout (submodule or --separate-git-dir)
esac

pr_number_of() { printf '%s' "$1" | sed -n -e 's#.*/pull/\([0-9][0-9]*\).*#\1#p' -e 's#^\#*\([0-9][0-9]*\)$#\1#p' | head -n 1; }

# ---- --clean: remove PR worktrees; the review logs stay
if [ "$CLEAN" = 1 ]; then
  ONLY=""
  if [ -n "$PR_ARG" ]; then
    ONLY=$(pr_number_of "$PR_ARG")
    [ -n "$ONLY" ] || fail "give a PR number or link to clean, or nothing to clean them all"
  fi
  REMOVED=""
  for d in "$TREES"/pr-*; do
    [ -e "$d" ] || continue
    if [ -n "$ONLY" ] && [ "$d" != "$TREES/pr-$ONLY" ]; then continue; fi
    if git worktree remove --force "$d" >/dev/null 2>&1; then
      REMOVED="$REMOVED $(basename "$d")"
    else
      add_warn "could not remove $d; remove it with: git worktree remove --force '$d'"
    fi
  done
  git worktree prune >/dev/null 2>&1
  rmdir "$TREES" 2>/dev/null
  out "status: ok"
  out "removed_worktrees:${REMOVED:- none}"
  out "review_logs: kept in $REV/pr-<n>/"
  if [ -n "$WARN" ]; then out "warnings:"; printf '%s' "$WARN"; fi
  exit 0
fi

[ -f "$SCOPE" ] || fail "cannot find daily-review's scope.sh at $SCOPE; reinstall the daily-review plugin"
[ -n "$PR_ARG" ] || fail "give a pull request link or number, for example /review-pr https://github.com/owner/repo/pull/12"
command -v gh >/dev/null 2>&1 || fail "the GitHub CLI (gh) is not installed. Install it from https://cli.github.com, then run: gh auth login"
command -v python3 >/dev/null 2>&1 || fail "python3 is needed to read the GitHub CLI's output"

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/review-pr.XXXXXX") || fail "cannot create a temporary folder"
trap 'rm -rf "$TMPD"' EXIT

# ---- The PR, from GitHub
gh pr view "$PR_ARG" --json number,title,url,state,isDraft,isCrossRepository,author,baseRefName,headRefName,headRefOid,body \
  > "$TMPD/pr.json" 2> "$TMPD/pr.err" \
  || fail "gh pr view $PR_ARG failed: $(head -n 3 "$TMPD/pr.err" | tr '\n' ' ')(if you are not logged in, run gh auth login; for a PR in another repository, pass its full link)"

python3 -I - "$TMPD/pr.json" "$TMPD/desc.md" > "$TMPD/vars.sh" <<'PY' || fail "could not read the PR details from gh"
import json, re, shlex, sys
d = json.load(open(sys.argv[1]))
m = re.match(r'https?://([^/]+)/([^/]+)/([^/]+)/pull/(\d+)', d.get("url", ""))
if not m:
    sys.exit(1)
author = (d.get("author") or {}).get("login") or "unknown"
vals = {
    "PR_HOST": m.group(1), "PR_OWNER": m.group(2), "PR_REPO": m.group(3),
    "PR_NUM": str(d["number"]), "PR_URL": d["url"], "PR_TITLE": d.get("title") or "",
    "PR_STATE": d.get("state") or "", "PR_DRAFT": "yes" if d.get("isDraft") else "no",
    "PR_FORK": "yes" if d.get("isCrossRepository") else "no",
    "PR_AUTHOR": author, "PR_BASE": d.get("baseRefName") or "",
    "PR_HEAD_BRANCH": d.get("headRefName") or "", "PR_HEAD_OID": d.get("headRefOid") or "",
}
for k, v in vals.items():
    print("%s=%s" % (k, shlex.quote(" ".join(v.split()) if k == "PR_TITLE" else v)))
body = (d.get("body") or "").replace("\r\n", "\n").strip() or "(no description)"
with open(sys.argv[2], "w") as f:
    f.write("# %s\n\n%s by @%s\n\n%s\n" % (d.get("title") or "", d["url"], author, body))
PY
. "$TMPD/vars.sh"
[ -n "$PR_BASE" ] || fail "GitHub did not return the PR's base branch"
CHECKS=$(gh pr view "$PR_URL" --json statusCheckRollup 2>/dev/null | python3 -I -c '
import json, sys
try:
    items = json.load(sys.stdin).get("statusCheckRollup") or []
except ValueError:
    sys.exit(1)
ok, bad, wait = 0, [], 0
for c in items:
    name = c.get("name") or c.get("context") or "?"
    if "conclusion" not in c and "state" in c:
        st = (c.get("state") or "").upper()
        if st == "SUCCESS": ok += 1
        elif st in ("FAILURE", "ERROR"): bad.append(name)
        else: wait += 1
        continue
    concl = (c.get("conclusion") or "").upper()
    if (c.get("status") or "COMPLETED").upper() != "COMPLETED" or not concl:
        wait += 1
    elif concl in ("SUCCESS", "NEUTRAL", "SKIPPED"):
        ok += 1
    elif concl != "STALE":
        bad.append(name)
if not items:
    print("none reported for the head commit")
else:
    parts = ["%d passed" % ok]
    if bad:
        parts.append("%d failed (%s)" % (len(bad), ", ".join(sorted(set(bad))[:8])))
    if wait:
        parts.append("%d not finished" % wait)
    print(", ".join(parts))
' 2>/dev/null)
[ -n "$CHECKS" ] || CHECKS="unknown (gh could not read them)"
REPO_SLUG="$PR_OWNER/$PR_REPO"
case "$PR_STATE" in
  MERGED) fail "PR #$PR_NUM is already merged. /review-pr reviews open pull requests; to review the merged code, use /daily-review on $PR_BASE" ;;
  CLOSED) add_warn "PR #$PR_NUM is closed; GitHub still accepts review comments on it" ;;
esac

# ---- The remote in this clone that points at the PR's repository
norm_url() {  # prints host/owner/repo in lower case
  case "$1" in
    *://*) printf '%s' "$1" | sed -e 's#^[^:]*://##' -e 's#^[^@/]*@##' -e 's#^\([^/:]*\):[0-9]*/#\1/#' ;;
    *) printf '%s' "$1" | sed -e 's#^[^@/:]*@##' -e 's#^\([^/:]*\):#\1/#' ;;
  esac | sed -e 's#/*$##' -e 's#\.git$##' | tr 'A-Z' 'a-z'
}
want=$(printf '%s/%s' "$PR_HOST" "$REPO_SLUG" | tr 'A-Z' 'a-z')
want_path=$(printf '%s' "$REPO_SLUG" | tr 'A-Z' 'a-z')
REMOTE=""; BY_PATH=""
for r in $(git remote); do
  n=$(norm_url "$(git config --get "remote.$r.url" 2>/dev/null)")
  if [ "$n" = "$want" ]; then REMOTE="$r"; break; fi
  # An SSH host alias (git@github-work:owner/repo) still names the same repository.
  [ -z "$BY_PATH" ] && [ "${n#*/}" = "$want_path" ] && BY_PATH="$r"
done
[ -n "$REMOTE" ] || REMOTE="$BY_PATH"
[ -n "$REMOTE" ] || fail "this clone has no remote for $REPO_SLUG. Run /review-pr from a clone of it, or add the remote: git remote add upstream https://$PR_HOST/$REPO_SLUG.git"

# ---- Fetch the PR head and its base branch (this only updates remote-tracking refs)
git fetch --quiet --no-tags "$REMOTE" "refs/pull/$PR_NUM/head" 2> "$TMPD/fetch.err" \
  || fail "could not fetch PR #$PR_NUM from $REMOTE: $(head -n 2 "$TMPD/fetch.err" | tr '\n' ' ')"
SHA=$(git rev-parse --verify -q "FETCH_HEAD^{commit}") || fail "could not read the fetched PR head"
git fetch --quiet --no-tags "$REMOTE" "+refs/heads/$PR_BASE:refs/remotes/$REMOTE/$PR_BASE" 2> "$TMPD/fetch.err" \
  || fail "could not fetch the base branch $PR_BASE from $REMOTE: $(head -n 2 "$TMPD/fetch.err" | tr '\n' ' ')"
BASE_REF="$REMOTE/$PR_BASE"
if [ -n "$PR_HEAD_OID" ] && [ "$SHA" != "$PR_HEAD_OID" ]; then
  add_warn "the PR was updated while it was being fetched; reviewing $(git rev-parse --short "$SHA"), its latest commit"
fi
MB=$(git merge-base "$BASE_REF" "$SHA" 2>/dev/null) || fail "PR #$PR_NUM has no common history with $BASE_REF"

# ---- Keep .reviews/ out of git (scope.sh does this too, but the worktree comes first)
EXCLUDE_FILE=$(git rev-parse --git-path info/exclude 2>/dev/null)
case "$EXCLUDE_FILE" in /*) ;; *) EXCLUDE_FILE="$MAIN/$EXCLUDE_FILE" ;; esac
if ! grep -qxF '/.reviews/' "$EXCLUDE_FILE" 2>/dev/null; then
  mkdir -p "$(dirname "$EXCLUDE_FILE")" 2>/dev/null
  printf '\n# daily-review: local review logs\n/.reviews/\n' >> "$EXCLUDE_FILE" 2>/dev/null \
    || add_warn "could not add /.reviews/ to $EXCLUDE_FILE; add .reviews/ to .gitignore so review files are never committed"
fi

# ---- Worktree at the PR head, without running the repository's git hooks
DIR="$REV/pr-$PR_NUM"; TREE="$TREES/pr-$PR_NUM"; WORKD="$REV/.work/pr-$PR_NUM"
mkdir -p "$DIR" "$WORKD" 2>/dev/null || fail "cannot create $DIR (check folder permissions)"
git worktree prune >/dev/null 2>&1
if [ -f "$TREE/.git" ]; then
  git -C "$TREE" -c core.hooksPath=/dev/null checkout --quiet --force --detach "$SHA" 2> "$TMPD/wt.err" \
    || fail "could not update the worktree $TREE: $(head -n 2 "$TMPD/wt.err" | tr '\n' ' ')"
elif [ -e "$TREE" ]; then
  fail "$TREE exists but is not a git worktree; move it away and run again"
else
  git -c core.hooksPath=/dev/null worktree add --detach "$TREE" "$SHA" > /dev/null 2> "$TMPD/wt.err" \
    || fail "git worktree add failed: $(head -n 2 "$TMPD/wt.err" | tr '\n' ' ')"
fi
EXTRA=$(git -C "$TREE" status --porcelain 2>/dev/null | head -n 5 | tr '\n' ' ')
[ -n "$EXTRA" ] && add_warn "the worktree has files that are not in the PR: $EXTRA"

# ---- REVIEW.md: the lead's rules, never a copy that a developer's branch can change.
# 1. your checkout's copy when you are on the PR's base branch (it has your uncommitted edits)
# 2. the base branch's committed copy   3. the default branch's committed copy
# 4. an untracked REVIEW.md in your checkout (yours, not committed anywhere)
CUR_BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null)
DEF=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
RMD="none"; RMD_NOTE=""
if [ "$CUR_BRANCH" = "$PR_BASE" ] && [ -f "$MAIN/REVIEW.md" ]; then
  RMD="$MAIN/REVIEW.md"; RMD_NOTE="your checkout's copy, which is on $PR_BASE, the PR's base branch"
elif git cat-file -e "$BASE_REF:REVIEW.md" 2>/dev/null; then
  git show "$BASE_REF:REVIEW.md" > "$WORKD/REVIEW.from-base.md" 2>/dev/null
  RMD="$WORKD/REVIEW.from-base.md"; RMD_NOTE="from $BASE_REF, the PR's base branch"
elif [ -n "$DEF" ] && [ "$DEF" != "$BASE_REF" ] && git cat-file -e "$DEF:REVIEW.md" 2>/dev/null; then
  git show "$DEF:REVIEW.md" > "$WORKD/REVIEW.from-default.md" 2>/dev/null
  RMD="$WORKD/REVIEW.from-default.md"; RMD_NOTE="from $DEF, the default branch; $BASE_REF has no REVIEW.md"
elif [ -f "$MAIN/REVIEW.md" ] && ! git ls-files --error-unmatch REVIEW.md >/dev/null 2>&1; then
  RMD="$MAIN/REVIEW.md"; RMD_NOTE="your checkout's copy, not committed yet; $BASE_REF has none"
else
  RMD_NOTE="neither $BASE_REF nor ${DEF:-the default branch} has a REVIEW.md"
fi
if ! git diff --quiet "$MB" "$SHA" -- REVIEW.md 2>/dev/null; then
  RMD_NOTE="$RMD_NOTE; this PR also changes REVIEW.md, and those changes are not applied"
fi

# ---- PR description, the comments already on it, and the PR details for post_review.py
cp "$TMPD/desc.md" "$WORKD/pr-description.md"
H="--hostname $PR_HOST"
gh api $H --paginate "repos/$REPO_SLUG/pulls/$PR_NUM/comments" > "$TMPD/c1.json" 2>/dev/null \
  || { : > "$TMPD/c1.json"; add_warn "could not read the PR's review comments"; }
gh api $H --paginate "repos/$REPO_SLUG/pulls/$PR_NUM/reviews" > "$TMPD/c2.json" 2>/dev/null \
  || { : > "$TMPD/c2.json"; add_warn "could not read the PR's reviews"; }
gh api $H --paginate "repos/$REPO_SLUG/issues/$PR_NUM/comments" > "$TMPD/c3.json" 2>/dev/null \
  || { : > "$TMPD/c3.json"; add_warn "could not read the PR's conversation"; }
gh api $H user > "$TMPD/user.json" 2>/dev/null || : > "$TMPD/user.json"
COMMENT_INFO=$(python3 -I - "$TMPD" "$WORKD/pr-comments.md" <<'PY'
import json, sys
def items(path):
    """gh --paginate prints one JSON array, or one array per page in older versions."""
    try:
        text = open(path).read()
    except OSError:
        return []
    dec, i, out = json.JSONDecoder(), 0, []
    while i < len(text):
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        try:
            obj, i = dec.raw_decode(text, i)
        except ValueError:
            break
        out.extend(obj if isinstance(obj, list) else [obj])
    return [x for x in out if isinstance(x, dict)]
def short(s, n=2000):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[:n] + " [cut: the full text is on GitHub]"
d = sys.argv[1]
try:
    me = json.load(open(d + "/user.json")).get("login") or ""
except (OSError, ValueError, AttributeError):
    me = ""
def who(x):
    login = (x.get("user") or {}).get("login") or "?"
    return "@" + login + (" (you)" if login == me else "")
reviews = items(d + "/c2.json")
# GitHub shows a pending (unsubmitted) review only to its author, so any pending review here is yours.
pending = set(r.get("id") for r in reviews if r.get("state") == "PENDING")
entries, n_pending = [], 0   # (time, text); pending items have no time and go last
for c in items(d + "/c1.json"):
    end = c.get("line") or c.get("original_line") or "?"
    start = c.get("start_line") or c.get("original_start_line")
    where = "`%s:%s`" % (c.get("path", "?"), "%s-%s" % (start, end) if start and start != end else end)
    note = ""
    if c.get("line") is None and c.get("original_line"):
        note = " (outdated: on an earlier commit of the PR)"
    if c.get("pull_request_review_id") in pending:
        note, n_pending = " (in your pending review, not submitted yet)", n_pending + 1
    elif c.get("in_reply_to_id"):
        note += " (reply)"
    entries.append((c.get("created_at") or "~", "%s on %s%s: %s" % (who(c), where, note, short(c.get("body")))))
for r in reviews:
    if (r.get("body") or "").strip():
        state = "pending review, not submitted yet" if r.get("id") in pending else "review, " + (r.get("state") or "").lower()
        entries.append((r.get("submitted_at") or "~", "%s (%s): %s" % (who(r), state, short(r.get("body")))))
for c in items(d + "/c3.json"):
    entries.append((c.get("created_at") or "~", "%s in the conversation: %s" % (who(c), short(c.get("body")))))
entries.sort(key=lambda e: e[0])
lines = ["- %s%s" % ("" if t == "~" else t[:10] + " ", text) for t, text in entries]
with open(sys.argv[2], "w") as f:
    f.write("# Comments already on the PR, oldest first\n\n" + ("\n".join(lines) if lines else "None.") + "\n")
print(len(lines))
print("yes, with %d inline comments" % n_pending if pending else "none")
PY
)
N_COMMENTS=$(printf '%s\n' "$COMMENT_INFO" | sed -n 1p)
MY_PENDING=$(printf '%s\n' "$COMMENT_INFO" | sed -n 2p)

python3 -I - "$WORKD/pr.json" "$PR_HOST" "$REPO_SLUG" "$PR_NUM" "$PR_URL" "$PR_AUTHOR" "$PR_BASE" "$BASE_REF" \
  "$PR_HEAD_BRANCH" "$SHA" "$MB" "$TREE" "$MAIN" <<'PY' || add_warn "could not save the PR details for post_review.py"
import json, sys
keys = ["host", "repo", "number", "url", "author", "base_branch", "base_ref", "head_branch",
        "head_sha", "merge_base", "tree", "checkout"]
info = dict(zip(keys, sys.argv[2:]))
info["number"] = int(info["number"])
with open(sys.argv[1], "w") as f:
    json.dump(info, f, indent=1)
PY

COMMENTABLE="$WORKD/commentable.txt"
python3 -I "$POST" --ranges --info "$WORKD/pr.json" > "$COMMENTABLE" 2> "$TMPD/ranges.err" \
  || { add_warn "could not list the commentable lines: $(head -n 1 "$TMPD/ranges.err")"; COMMENTABLE="none"; }

# ---- The review scope, from daily-review's scope.sh inside the worktree
SCOPE_OUT=$(cd "$TREE" && DAILY_REVIEW_LOG_ROOT="$REV" DAILY_REVIEW_SLUG="pr-$PR_NUM" \
  DAILY_REVIEW_BRANCH="$PR_HEAD_BRANCH" DAILY_REVIEW_REVIEW_MD="$RMD" DAILY_REVIEW_REVIEW_MD_NOTE="$RMD_NOTE" \
  bash "$SCOPE" --base "$BASE_REF" $PASS 2>&1)
LOG_FILE=$(printf '%s\n' "$SCOPE_OUT" | sed -n 's/^log_file: //p' | head -n 1)
PREV_LOG=$(printf '%s\n' "$SCOPE_OUT" | sed -n 's/^previous_review: \(.*\.md\).*/\1/p' | head -n 1)
# Before its first PR review, the lead may have reviewed this branch with /daily-review.
BRANCH_REVIEW=""
if [ -z "$PREV_LOG" ] && [ -n "$LOG_FILE" ] && [ "$PR_FORK" = "no" ] && [ "$PR_HEAD_BRANCH" != "$PR_BASE" ]; then
  BSLUG=$(printf '%s' "$PR_HEAD_BRANCH" | sed -e 's#/#__#g' -e 's#[^A-Za-z0-9._-]#-#g')
  B=$(ls -1 "$REV/$BSLUG" 2>/dev/null | sed -n \
    -e 's/^\(review-\([0-9][0-9]*\)-\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9]\{4\}\)\.md\)$/\3 \2 \1/p' \
    -e 's/^\(\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9]\{4\}\)_[0-9a-f][0-9a-f]*\.md\)$/\2 0 \1/p' \
    | sort -k1,1 -k2,2n | tail -n 1 | cut -d' ' -f3)
  [ -n "$B" ] && BRANCH_REVIEW="$REV/$BSLUG/$B"
fi
PREV_DRAFT=""
if [ -n "$PREV_LOG" ] && [ -f "${PREV_LOG%.md}.github.md" ]; then
  PREV_DRAFT="${PREV_LOG%.md}.github.md"
  MARK="$WORKD/$(basename "${PREV_LOG%.md}").github.posted.json"
  if [ -f "$MARK" ]; then
    PREV_DRAFT="$PREV_DRAFT (posted $(sed -n 's/.*"at": "\([^"]*\)".*/\1/p' "$MARK" | head -n 1))"
  else
    PREV_DRAFT="$PREV_DRAFT (never posted)"
  fi
fi

out "pr_status: ok"
out "pr: $PR_URL (#$PR_NUM, $(printf '%s' "$PR_STATE" | tr 'A-Z' 'a-z'), draft: $PR_DRAFT)"
out "title: $PR_TITLE"
out "author: @$PR_AUTHOR"
out "base_branch: $PR_BASE (compared with $BASE_REF; merge base $(git rev-parse --short "$MB"))"
out "pr_head: $SHA ($PR_HEAD_BRANCH)"
out "worktree: $TREE"
out "  The PR's code, checked out at its head. Read the PR's files here: your own checkout is on another branch."
out "description: $WORKD/pr-description.md"
out "checks: $CHECKS"
out "existing_comments: ${N_COMMENTS:-0} ($WORKD/pr-comments.md)"
out "your_pending_review: ${MY_PENDING:-none}"
out "commentable_lines: $COMMENTABLE"
[ -n "$LOG_FILE" ] && out "github_draft: ${LOG_FILE%.md}.github.md"
[ -n "$PREV_DRAFT" ] && out "previous_draft: $PREV_DRAFT"
[ -n "$BRANCH_REVIEW" ] && out "branch_review: $BRANCH_REVIEW (your last /daily-review of $PR_HEAD_BRANCH)"
if [ -n "$WARN" ]; then out "pr_warnings:"; printf '%s' "$WARN"; else out "pr_warnings: none"; fi
out ""
out "--- scope (daily-review) ---"
printf '%s\n' "$SCOPE_OUT"
exit 0
