#!/usr/bin/env bash
# daily-review scope: decides which commits to review and prepares the work files.
#
# Default range: everything since the last review of this branch. First review of a
# branch: everything since it left the base branch. Commits that came in by merging
# the base branch into this branch are left out.
#
# Flags (all optional):
#   --since <ref>    review <ref>..HEAD
#   --days <n>       review commits from the last n days (by commit date)
#   --base <branch>  base branch for first reviews (default: "Base branch:" in REVIEW.md,
#                    then origin/HEAD, main, master, develop)
#   --full           ignore earlier reviews; review the whole branch
#   --rerun          review the same range as the last review again
#   --architecture   no commit range: prepare a whole-system architecture review
#
# Environment (set by /review-pr, which runs this inside a PR worktree; unset, nothing changes):
#   DAILY_REVIEW_LOG_ROOT      folder for logs and scratch files instead of .reviews
#   DAILY_REVIEW_SLUG          log folder name instead of the branch name
#   DAILY_REVIEW_BRANCH        branch label shown in the report and the log
#   DAILY_REVIEW_REVIEW_MD     REVIEW.md to use instead of the one in the checkout ("none": no REVIEW.md)
#   DAILY_REVIEW_REVIEW_MD_NOTE  why that file is used, shown next to it
#
# Sources of truth are the files listed under "## Sources of truth" in REVIEW.md.
# They are read from the repository. Word and PDF files are converted to text in the
# scratch folder (.reviews/.work) on every run; that text is never kept as a copy.
#
# Always exits 0 and reports problems as "status: error", because a non-zero exit
# would abort the skill. Written for macOS /bin/bash 3.2 and BSD tools.

# Never take git's optional index lock: the review stays read-only and never
# blocks git commands running at the same time (IDE, another terminal).
export GIT_OPTIONAL_LOCKS=0

out() { printf '%s\n' "$*"; }
fail() { out "status: error"; out "error: $*"; exit 0; }
WARN=""
add_warn() { WARN="${WARN}  - $*
"; }

SINCE=""; DAYS=""; BASE_OVERRIDE=""; FULL=0; RERUN=0; ARCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) if [ $# -ge 2 ]; then SINCE="$2"; shift 2; else shift; fi ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    --days) if [ $# -ge 2 ]; then DAYS="$2"; shift 2; else shift; fi ;;
    --days=*) DAYS="${1#--days=}"; shift ;;
    --base) if [ $# -ge 2 ]; then BASE_OVERRIDE="$2"; shift 2; else shift; fi ;;
    --base=*) BASE_OVERRIDE="${1#--base=}"; shift ;;
    --full) FULL=1; shift ;;
    --rerun) RERUN=1; shift ;;
    --architecture) ARCH=1; shift ;;
    *..*) SINCE="${1%%..*}"; RANGE_END="${1#*..}"; shift ;;
    *) shift ;;
  esac
done

command -v git >/dev/null 2>&1 || fail "git is not installed"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not inside a git repository"
cd "$ROOT" || fail "cannot open $ROOT"
HEAD_SHA=$(git rev-parse --verify -q HEAD) || fail "this repository has no commits"
HEAD7=$(git rev-parse --short HEAD)
BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null) || BRANCH="detached-$HEAD7"
[ -n "${DAILY_REVIEW_BRANCH:-}" ] && BRANCH="$DAILY_REVIEW_BRANCH"
SLUG=$(printf '%s' "$BRANCH" | sed -e 's#/#__#g' -e 's#[^A-Za-z0-9._-]#-#g')
[ -n "${DAILY_REVIEW_SLUG:-}" ] && SLUG="$DAILY_REVIEW_SLUG"
EMPTY_TREE=$(git hash-object -t tree /dev/null)
is_commit() { git rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }

if [ -n "${RANGE_END:-}" ] && [ "$RANGE_END" != "HEAD" ]; then
  END_SHA=$(git rev-parse --verify -q "$RANGE_END^{commit}" 2>/dev/null)
  [ "$END_SHA" = "$HEAD_SHA" ] || fail "reviews always end at the checked-out commit. Check out $RANGE_END first, then run with --since ${SINCE}"
fi

LOG_ROOT="${DAILY_REVIEW_LOG_ROOT:-.reviews}"
LOG_DIR="$LOG_ROOT/$SLUG"
WORK="$LOG_ROOT/.work/$SLUG"
mkdir -p "$LOG_DIR" "$WORK" 2>/dev/null || fail "cannot create $LOG_DIR (check folder permissions)"
STAMP=$(date '+%Y-%m-%d_%H%M')

# Review logs are named review-<n>-<YYYY-MM-DD>_<HHMM>.md; older ones <YYYY-MM-DD>_<HHMM>_<head7>.md.
latest_log() {  # $1 = folder; prints the newest log's file name
  ls -1 "$1" 2>/dev/null | sed -n \
    -e 's/^\(review-\([0-9][0-9]*\)-\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9]\{4\}\)\.md\)$/\3 \2 \1/p' \
    -e 's/^\(\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9]\{4\}\)_[0-9a-f][0-9a-f]*\.md\)$/\2 0 \1/p' \
    | sort -k1,1 -k2,2n | tail -n 1 | cut -d' ' -f3
}
next_log_name() {  # $1 = folder; prints the file name for a new log
  n=$(ls -1 "$1" 2>/dev/null | sed -n 's/^review-\([0-9][0-9]*\)-[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9]\{4\}\.md$/\1/p' | sort -n | tail -n 1)
  printf 'review-%s-%s.md' "$(( ${n:-0} + 1 ))" "$STAMP"
}

# Keep the local review logs out of git without touching the shared .gitignore.
EXCLUDE_FILE=$(git rev-parse --git-path info/exclude 2>/dev/null)
if [ -n "$EXCLUDE_FILE" ] && ! grep -qxF '/.reviews/' "$EXCLUDE_FILE" 2>/dev/null; then
  mkdir -p "$(dirname "$EXCLUDE_FILE")" 2>/dev/null
  printf '\n# daily-review: local review logs\n/.reviews/\n' >> "$EXCLUDE_FILE" 2>/dev/null \
    || add_warn "could not add /.reviews/ to $EXCLUDE_FILE; add .reviews/ to .gitignore so logs are never committed"
fi

# ---- Default branch, REVIEW.md and base branch
DEFAULT_REF=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
if [ -z "$DEFAULT_REF" ]; then
  for c in origin/main main origin/master master origin/develop develop; do
    if is_commit "$c"; then DEFAULT_REF="$c"; break; fi
  done
fi

rm -f "$WORK/REVIEW.base.md"
REVIEW_MD="none"; REVIEW_FILE="none"
if [ "${DAILY_REVIEW_REVIEW_MD:-}" = "none" ]; then
  REVIEW_MD="none (${DAILY_REVIEW_REVIEW_MD_NOTE:-set by the caller})"
elif [ -n "${DAILY_REVIEW_REVIEW_MD:-}" ] && [ -f "$DAILY_REVIEW_REVIEW_MD" ]; then
  REVIEW_FILE="$DAILY_REVIEW_REVIEW_MD"
  REVIEW_MD="$REVIEW_FILE (${DAILY_REVIEW_REVIEW_MD_NOTE:-set by the caller})"
elif [ -f REVIEW.md ]; then
  REVIEW_FILE="REVIEW.md"; REVIEW_MD="REVIEW.md"
elif [ -n "$DEFAULT_REF" ] && git cat-file -e "$DEFAULT_REF:REVIEW.md" 2>/dev/null; then
  git show "$DEFAULT_REF:REVIEW.md" > "$WORK/REVIEW.base.md" 2>/dev/null
  REVIEW_FILE="$WORK/REVIEW.base.md"
  REVIEW_MD="$REVIEW_FILE (copied from $DEFAULT_REF; this branch has no REVIEW.md)"
fi

BASE_NAME="$BASE_OVERRIDE"
if [ -z "$BASE_NAME" ] && [ "$REVIEW_FILE" != "none" ]; then
  BASE_NAME=$(grep -i -m1 '^[*_ ]*base branch[*_ ]*:' "$REVIEW_FILE" 2>/dev/null \
    | sed -e 's/^[^:]*:[[:space:]]*//' -e 's#[^A-Za-z0-9._/-]##g')
fi
[ -n "$BASE_NAME" ] || BASE_NAME="$DEFAULT_REF"

BASE_REF=""
case "$BASE_NAME" in
  "") ;;
  origin/*) is_commit "$BASE_NAME" && BASE_REF="$BASE_NAME" ;;
  *)
    if is_commit "origin/$BASE_NAME" && is_commit "$BASE_NAME"; then
      # Use whichever copy is newer; the remote one when they have diverged.
      if git merge-base --is-ancestor "origin/$BASE_NAME" "$BASE_NAME" 2>/dev/null; then BASE_REF="$BASE_NAME"
      else BASE_REF="origin/$BASE_NAME"; fi
    elif is_commit "origin/$BASE_NAME"; then BASE_REF="origin/$BASE_NAME"
    elif is_commit "$BASE_NAME"; then BASE_REF="$BASE_NAME"
    fi ;;
esac
[ -n "$BASE_NAME" ] && [ -z "$BASE_REF" ] && add_warn "base branch '$BASE_NAME' not found locally; run git fetch or pass --base <branch>"

ON_BASE=0
if [ -n "$BASE_REF" ] && git merge-base --is-ancestor HEAD "$BASE_REF" 2>/dev/null; then ON_BASE=1; fi

# ---- Sources of truth, from REVIEW.md
SCRIPTS_DIR=$(cd "$(dirname "$0")" && pwd)
BT=$(printf '\140')
SRC_DIR="$WORK/sources"
mkdir -p "$SRC_DIR" 2>/dev/null
section_paths() {
  [ "$REVIEW_FILE" != "none" ] || return 0
  awk -v want="$1" '/^## /{ insec = (index(tolower($0), want) > 0); next } insec && /^[[:space:]]*[-*] /{ print }' "$REVIEW_FILE" \
    | grep -o "${BT}[^${BT}]*${BT}" | tr -d "$BT" | grep -E '^[^[:space:]]+$' | grep -E '/|[.][A-Za-z0-9]+$'
}
expand_paths() {
  while read -r p; do
    [ -n "$p" ] || continue
    found=0
    for f in $p; do
      if [ -e "$f" ]; then printf '%s\n' "$f"; found=1; fi
    done
    [ "$found" = 1 ] || printf '%s\n' "$p"
  done
}
to_text() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    *.docx)
      if command -v python3 >/dev/null 2>&1 && python3 -I "$SCRIPTS_DIR/docx2md.py" "$1" "$2.md" >/dev/null 2>&1; then printf '%s\n' "$2.md"
      elif command -v pandoc >/dev/null 2>&1 && pandoc -f docx -t gfm --wrap=none "$1" -o "$2.md" >/dev/null 2>&1; then printf '%s\n' "$2.md"
      elif command -v textutil >/dev/null 2>&1 && textutil -convert txt -output "$2.txt" "$1" >/dev/null 2>&1; then printf '%s\n' "$2.txt"
      fi ;;
    *.pdf)
      if command -v pdftotext >/dev/null 2>&1 && pdftotext -layout "$1" "$2.txt" >/dev/null 2>&1; then printf '%s\n' "$2.txt"
      else printf '%s\n' "$1"; fi ;;
    *) printf '%s\n' "$1" ;;
  esac
}
SOURCES=$(section_paths "sources of truth" | expand_paths)
IGNORE_LIST=$(section_paths "not sources" | expand_paths)
SOURCES_CONFIRMED="no"
if [ "$REVIEW_FILE" != "none" ] && grep -qiE '^[*_ ]*sources confirmed[*_ ]*:[*_ ]*yes' "$REVIEW_FILE" 2>/dev/null; then SOURCES_CONFIRMED="yes"; fi
SRC_OUT=""; SRC_MISSING=""
while read -r f; do
  [ -n "$f" ] || continue
  flat=$(printf '%s' "$f" | sed -e 's#/#__#g')
  src="$f"; note=""
  if [ ! -e "$f" ]; then
    if [ -n "$BASE_REF" ] && git cat-file -e "$BASE_REF:$f" 2>/dev/null; then
      mkdir -p "$SRC_DIR/base" 2>/dev/null
      git show "$BASE_REF:$f" > "$SRC_DIR/base/$flat" 2>/dev/null
      src="$SRC_DIR/base/$flat"; note=" (missing on this branch; using $BASE_REF's version)"
    else
      SRC_MISSING="$SRC_MISSING  $f
"
      continue
    fi
  fi
  case "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" in
    *.docx|*.pdf)
      h=$(git hash-object "$src" 2>/dev/null)
      readp=$(cat "$SRC_DIR/$flat.path" 2>/dev/null)
      if [ -z "$h" ] || [ "$h" != "$(cat "$SRC_DIR/$flat.hash" 2>/dev/null)" ] || [ ! -f "$readp" ]; then
        readp=$(to_text "$src" "$SRC_DIR/$flat")
        printf '%s' "$h" > "$SRC_DIR/$flat.hash"; printf '%s' "$readp" > "$SRC_DIR/$flat.path"
      fi
      if [ -z "$readp" ]; then
        SRC_OUT="$SRC_OUT  $f$note: could not convert to text (needs python3, pandoc or textutil)
"
      elif [ -f "${readp%.*}.index.md" ]; then
        SRC_OUT="$SRC_OUT  $f$note -> read $readp (section index: ${readp%.*}.index.md)
"
      else
        SRC_OUT="$SRC_OUT  $f$note -> read $readp
"
      fi ;;
    *)
      if [ -n "$note" ]; then SRC_OUT="$SRC_OUT  $f$note -> read $src
"
      else SRC_OUT="$SRC_OUT  $f
"; fi ;;
  esac
done <<EOF
$SOURCES
EOF
DECISIONS="none"; [ -f "$LOG_ROOT/decisions.md" ] && DECISIONS="$LOG_ROOT/decisions.md"
print_sources() {
  out "sources_confirmed: $SOURCES_CONFIRMED"
  if [ -n "$SRC_OUT" ]; then out "sources:"; printf '%s' "$SRC_OUT"; else out "sources: none"; fi
  if [ -n "$SRC_MISSING" ]; then out "sources_missing (listed in REVIEW.md, not found):"; printf '%s' "$SRC_MISSING"; else out "sources_missing: none"; fi
}

# ---- Architecture mode: no commit range, the whole system at HEAD
if [ "$ARCH" = 1 ]; then
  ALOG_DIR="$LOG_ROOT/architecture"
  mkdir -p "$ALOG_DIR" 2>/dev/null
  APREV=$(latest_log "$ALOG_DIR")
  ALOG_FILE="$ALOG_DIR/$(next_log_name "$ALOG_DIR")"
  out "status: ok"
  out "mode: architecture"
  out "repo: $ROOT"
  out "branch: $BRANCH"
  out "head: $HEAD_SHA ($HEAD7)"
  out "review_md: $REVIEW_MD"
  out "decisions: $DECISIONS"
  print_sources
  out "code_map (tracked files per folder):"
  git ls-files 2>/dev/null | awk -F/ '{ if (NF > 2) print $1"/"$2; else if (NF == 2) print $1; else print "." }' \
    | sort | uniq -c | sort -rn | head -n 20 | awk '{ printf "  %s (%s files)\n", $2, $1 }'
  if [ -n "$APREV" ]; then out "previous_review: $ALOG_DIR/$APREV"; else out "previous_review: none"; fi
  out "log_file: $ALOG_FILE"
  out "log_frontmatter (first lines of the log file, copy exactly):"
  out "---"
  out "mode: architecture"
  out "branch: $BRANCH"
  out "head: $HEAD_SHA"
  out "date: $(date '+%Y-%m-%d %H:%M')"
  out "---"
  exit 0
fi

# ---- Previous review of this branch
PREV=""; PREV_HEAD=""; PREV_BASE=""
PREV_NAME=$(latest_log "$LOG_DIR")
if [ -n "$PREV_NAME" ]; then
  PREV="$LOG_DIR/$PREV_NAME"
  PREV_HEAD=$(sed -n 's/^[[:space:]]*head:[[:space:]]*\([0-9a-f]\{7,40\}\).*/\1/p' "$PREV" | head -n 1)
  PREV_BASE=$(sed -n 's/^[[:space:]]*base:[[:space:]]*\([0-9a-f]\{7,40\}\).*/\1/p' "$PREV" | head -n 1)
  [ -n "$PREV_HEAD" ] || add_warn "could not read 'head:' from $PREV; treating this as a first review"
fi

# ---- Choose the base commit
BASE=""; REASON=""; LOST_PREV=0
if [ -n "$SINCE" ]; then
  BASE=$(git rev-parse --verify -q "$SINCE^{commit}" 2>/dev/null) || fail "unknown commit or branch for --since: $SINCE"
  REASON="since $SINCE (argument)"
elif [ -n "$DAYS" ]; then
  case "$DAYS" in *[!0-9]*|"") fail "--days needs a whole number, e.g. --days 1" ;; esac
  BASE=$(git rev-list -1 --first-parent --before="$DAYS days ago" HEAD 2>/dev/null)
  [ -n "$BASE" ] || BASE="$EMPTY_TREE"
  REASON="commits from the last $DAYS day(s) (argument)"
elif [ "$RERUN" = 1 ]; then
  [ -n "$PREV_BASE" ] || fail "--rerun needs an earlier saved review of this branch; none found in $LOG_DIR"
  if [ "$PREV_BASE" = "$EMPTY_TREE" ]; then BASE="$EMPTY_TREE"
  else BASE=$(git rev-parse --verify -q "$PREV_BASE^{commit}" 2>/dev/null) || fail "base $PREV_BASE of the last review is not in this repository"; fi
  REASON="re-run of the last review ($PREV_NAME)"
elif [ "$FULL" = 0 ] && [ -n "$PREV_HEAD" ]; then
  PREV_FULL=$(git rev-parse --verify -q "$PREV_HEAD^{commit}" 2>/dev/null)
  if [ -n "$PREV_FULL" ] && [ "$PREV_FULL" = "$HEAD_SHA" ]; then
    out "status: nothing-new"
    out "branch: $BRANCH"
    out "head: $HEAD7"
    out "previous_review: $PREV"
    out "hint: did you pull the latest commits? Use --rerun to review the same range again."
    exit 0
  elif [ -n "$PREV_FULL" ] && git merge-base --is-ancestor "$PREV_FULL" HEAD 2>/dev/null; then
    BASE="$PREV_FULL"
    REASON="since the last review (${PREV_NAME%.md})"
  else
    add_warn "the last reviewed commit $(printf '%s' "$PREV_HEAD" | cut -c1-7) is no longer in this branch (rebased or force-pushed); reviewing the whole branch instead"
    LOST_PREV=1
  fi
fi

if [ -z "$BASE" ]; then
  [ -n "$BASE_REF" ] || fail "cannot find the base branch. Pass --base <branch>, or add a line 'Base branch: <name>' to REVIEW.md"
  if [ "$ON_BASE" = 1 ]; then
    BASE=$(git rev-list -1 --before="24 hours ago" HEAD 2>/dev/null)
    [ -n "$BASE" ] || BASE="$EMPTY_TREE"
    REASON="$BRANCH is the base branch (or already merged into $BASE_REF), so there is no fork point: commits from the last 24 hours (use --since <ref> or --days <n> to choose)"
  else
    BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null) || fail "$BRANCH has no common history with $BASE_REF; pass --base <branch>"
    if [ "$LOST_PREV" = 1 ]; then REASON="whole branch since it left $BASE_REF (last reviewed commit is gone)"
    else REASON="first review of this branch: everything since it left $BASE_REF (use --days 1 for only the last day)"; fi
  fi
fi

if [ "$BASE" = "$HEAD_SHA" ]; then
  out "status: nothing-new"
  out "branch: $BRANCH"
  out "head: $HEAD7"
  out "reason: $REASON"
  exit 0
fi

# ---- Leave out what came in from the base branch
FROM="$BASE"
LOG_ARGS="$BASE..HEAD"
MERGED_NOTE="no"
if [ "$BASE" = "$EMPTY_TREE" ]; then
  LOG_ARGS="HEAD"
elif [ -n "$BASE_REF" ] && [ "$ON_BASE" = 0 ]; then
  TOTAL=$(git rev-list --count "$BASE..HEAD" 2>/dev/null || echo 0)
  OWN=$(git rev-list --count HEAD "^$BASE" "^$BASE_REF" 2>/dev/null || echo 0)
  if [ "$TOTAL" -gt "$OWN" ]; then
    FROM_BASE_COUNT=$((TOTAL - OWN))
    MB2=$(git merge-base HEAD "$BASE_REF" 2>/dev/null)
    VT_OUT=$(git merge-tree --write-tree "$BASE" "$MB2" 2>/dev/null)
    VT_RC=$?
    VT=$(printf '%s\n' "$VT_OUT" | head -n 1)
    if [ "$VT_RC" = 0 ] && printf '%s' "$VT" | grep -qE '^[0-9a-f]{40,64}$'; then
      FROM="$VT"
      LOG_ARGS="HEAD ^$BASE ^$BASE_REF"
      MERGED_NOTE="yes: $FROM_BASE_COUNT commits from $BASE_REF were merged into this branch; their changes are left out"
    else
      MERGED_NOTE="yes: $FROM_BASE_COUNT commits from $BASE_REF were merged in and could not be separated (merge conflicts, or git older than 2.38); some diff lines came from $BASE_REF"
      add_warn "part of the diff came from merging $BASE_REF; skip hunks that are not this developer's work"
    fi
  fi
fi

# ---- Files that are not worth reviewing line by line
IGNORE_GLOBS='**/package-lock.json **/npm-shrinkwrap.json **/yarn.lock **/pnpm-lock.yaml **/poetry.lock **/Pipfile.lock **/uv.lock **/Cargo.lock **/composer.lock **/go.sum **/*.lock **/*.min.js **/*.min.css **/*.map **/*.snap **/__snapshots__/** **/dist/** **/build/** **/.next/** **/node_modules/** **/*.tsbuildinfo **/*.png **/*.jpg **/*.jpeg **/*.gif **/*.webp **/*.ico **/*.pdf **/*.docx **/*.pptx **/*.xlsx **/*.zip **/*.woff **/*.woff2 **/*.ttf **/*.mp4'
set -f
EXCL=""; INCL=""
for g in $IGNORE_GLOBS; do
  EXCL="$EXCL :(exclude,glob)$g"
  INCL="$INCL :(glob)$g"
done

DIFF_FILE="$WORK/diff.patch"
COMMITS_FILE="$WORK/commits.txt"
git diff -M -U8 --no-color --no-ext-diff "$FROM" HEAD -- . $EXCL > "$DIFF_FILE" 2>/dev/null
NUMSTAT=$(git diff -M --numstat "$FROM" HEAD -- . $EXCL 2>/dev/null)
NAMESTAT=$(git diff -M --name-status "$FROM" HEAD -- . $EXCL 2>/dev/null)
IGNORED=$(git diff -M --numstat "$FROM" HEAD -- $INCL 2>/dev/null)
git log --no-merges --date=format:'%Y-%m-%d %H:%M' --format='--- %h  %ad  %an%n%s%n%b' $LOG_ARGS > "$COMMITS_FILE" 2>/dev/null
COMMIT_LINES=$(git log --no-merges --date=format:'%m-%d %H:%M' --format='%h %ad %<(14,trunc)%an %s' $LOG_ARGS 2>/dev/null)
N_COMMITS=$(git rev-list --count --no-merges $LOG_ARGS 2>/dev/null || echo 0)
N_MERGES=$(git rev-list --count --merges $LOG_ARGS 2>/dev/null || echo 0)
set +f

N_FILES=$(printf '%s\n' "$NUMSTAT" | grep -c . | tr -d ' ')
ADDS=$(printf '%s\n' "$NUMSTAT" | awk -F'\t' '$1 ~ /^[0-9]+$/ {s += $1} END {print s + 0}')
DELS=$(printf '%s\n' "$NUMSTAT" | awk -F'\t' '$2 ~ /^[0-9]+$/ {s += $2} END {print s + 0}')
REVIEWABLE=$((ADDS + DELS))
DIFF_LINES=$(wc -l < "$DIFF_FILE" | tr -d ' ')
N_IGNORED=$(printf '%s\n' "$IGNORED" | grep -c . | tr -d ' ')

if [ "$N_FILES" = 0 ]; then
  out "status: nothing-new"
  out "branch: $BRANCH"
  out "head: $HEAD7"
  out "reason: $REASON; no reviewable file changes (only ignored files or merges)"
  exit 0
fi

# ---- Context for the reviewers
SPECS_NEWER=""
if [ -n "$BASE_REF" ] && [ -n "$SOURCES" ]; then
  MBX=$(git merge-base HEAD "$BASE_REF" 2>/dev/null)
  if [ -n "$MBX" ]; then
    NEWER_ALL=$(git diff --name-only "$MBX" "$BASE_REF" 2>/dev/null)
    SPECS_NEWER=$(printf '%s\n' "$SOURCES" | while read -r f; do
      [ -n "$f" ] && printf '%s\n' "$NEWER_ALL" | grep -qxF "$f" && printf '%s\n' "$f"; done)
  fi
fi

# Spec files edited by the reviewed commits, and new plan-like docs not yet listed
CHANGED_ALL=$(git diff --name-only "$FROM" HEAD 2>/dev/null)
SRC_CHANGED=""
mkdir -p "$WORK/spec-changes" 2>/dev/null
rm -f "$WORK/spec-changes/"*.diff 2>/dev/null
while read -r f; do
  [ -n "$f" ] || continue
  printf '%s\n' "$CHANGED_ALL" | grep -qxF "$f" || continue
  flat=$(printf '%s' "$f" | sed -e 's#/#__#g')
  case "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" in
    *.docx|*.pdf)
      if git cat-file -e "$FROM:$f" 2>/dev/null; then
        git show "$FROM:$f" > "$SRC_DIR/old__$flat" 2>/dev/null
        oldt=$(to_text "$SRC_DIR/old__$flat" "$SRC_DIR/old__$flat.conv")
        newt=$(cat "$SRC_DIR/$flat.path" 2>/dev/null)
        if [ -n "$oldt" ] && [ -f "$newt" ] && [ "$oldt" != "$SRC_DIR/old__$flat" ]; then
          diff -u "$oldt" "$newt" > "$WORK/spec-changes/$flat.diff" 2>/dev/null
          SRC_CHANGED="$SRC_CHANGED  $f (text diff: $WORK/spec-changes/$flat.diff)
"
        else
          SRC_CHANGED="$SRC_CHANGED  $f (binary; no text diff)
"
        fi
      else
        SRC_CHANGED="$SRC_CHANGED  $f (added in this range)
"
      fi ;;
    *)
      st=$(printf '%s\n' "$NUMSTAT" | awk -F'\t' -v f="$f" '$3 == f { printf "+%s -%s", $1, $2 }')
      SRC_CHANGED="$SRC_CHANGED  $f ($st, in the diff file)
" ;;
  esac
done <<EOF
$SOURCES
EOF
DOC_CANDIDATES=$(printf '%s\n' "$CHANGED_ALL" | grep -iE '[.](md|markdown|docx|pdf|txt)$' \
  | grep -iE '(^|/)docs?/|plan|spec|architect|requirement|prd|adr|design|decision|roadmap|task' \
  | grep -vxF 'REVIEW.md' | while read -r f; do
      [ -n "$f" ] || continue
      printf '%s\n' "$SOURCES" | grep -qxF "$f" && continue
      printf '%s\n' "$IGNORE_LIST" | grep -qxF "$f" && continue
      printf '%s\n' "$f"
    done | head -n 10)
TESTS_IN_REPO=$(git ls-files 2>/dev/null \
  | grep -E '(^|/)(tests?|__tests__)/|(^|/)test_[^/]*[.]py$|_test[.](py|go)$|[.](test|spec)[.](js|jsx|ts|tsx|mjs|cjs)$' \
  | awk -F/ '{ if (NF > 2) print $1"/"$2; else if (NF == 2) print $1; else print "." }' \
  | sort | uniq -c | sort -rn | head -n 6 | awk '{ printf "%s (%s files), ", $2, $1 }' | sed 's/, $//')

if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null | head -n 1)" ]; then
  add_warn "uncommitted changes in the working tree; reviewers read files from disk and will see them"
fi
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
if [ -n "$UPSTREAM" ]; then
  BEHIND=$(git rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)
  [ "$BEHIND" -gt 0 ] && add_warn "$BRANCH is $BEHIND commits behind $UPSTREAM; pull first if you meant to review them"
fi
[ "$REVIEWABLE" -gt 3000 ] && add_warn "large change ($REVIEWABLE lines); reviewers cover data model, auth and core logic first"

LOG_FILE="$LOG_DIR/$(next_log_name "$LOG_DIR")"
OPEN_PREV=0
[ -n "$PREV" ] && OPEN_PREV=$(grep -cE '^([0-9]+\. |- #[0-9]+)' "$PREV" 2>/dev/null | tr -d ' ')
BASE_SHOW="$BASE"
BASE7=$(printf '%s' "$BASE" | cut -c1-7); [ "$BASE" = "$EMPTY_TREE" ] && BASE7="root"

# ---- Report
out "status: ok"
out "repo: $ROOT"
out "branch: $BRANCH"
out "head: $HEAD_SHA ($HEAD7, $(git log -1 --date=format:'%Y-%m-%d %H:%M' --format='%ad' HEAD))"
BASE_NOTE=""; [ "$BASE" = "$EMPTY_TREE" ] && BASE_NOTE=" (empty tree: start of history)"
out "base: $BASE_SHOW$BASE_NOTE"
out "range: $BASE7..$HEAD7"
out "reason: $REASON"
out "base_ref: ${BASE_REF:-none}"
out "merged_from_base: $MERGED_NOTE"
out "commits: $N_COMMITS (plus $N_MERGES merge commits)"
printf '%s\n' "$COMMIT_LINES" | head -n 40 | sed 's/^/  /'
[ "$N_COMMITS" -gt 40 ] && out "  ... $((N_COMMITS - 40)) more in the commits file"
out "files: $N_FILES reviewable, +$ADDS -$DELS ($REVIEWABLE changed lines); $N_IGNORED ignored"
printf '%s\n' "$NAMESTAT" | head -n 80 | awk -F'\t' '{ if (NF >= 3) printf "  %s %s -> %s\n", substr($1,1,1), $2, $3; else printf "  %s %s\n", $1, $2 }'
[ "$N_FILES" -gt 80 ] && out "  ... $((N_FILES - 80)) more in the diff file"
if [ "$N_IGNORED" -gt 0 ]; then
  out "ignored (lockfiles, build output, binaries):"
  printf '%s\n' "$IGNORED" | head -n 10 | awk -F'\t' '{ printf "  %s (+%s -%s)\n", $3, $1, $2 }'
fi
out "diff_file: $DIFF_FILE ($DIFF_LINES lines)"
out "commits_file: $COMMITS_FILE"
out "review_md: $REVIEW_MD"
out "decisions: $DECISIONS"
print_sources
if [ -n "$SRC_CHANGED" ]; then out "sources_changed_in_range (spec edits made by these commits):"; printf '%s' "$SRC_CHANGED"; else out "sources_changed_in_range: none"; fi
if [ -n "$DOC_CANDIDATES" ]; then
  out "doc_candidates (plan-like docs changed in this range, not listed as sources or ignored):"
  printf '%s\n' "$DOC_CANDIDATES" | sed 's/^/  /'
else
  out "doc_candidates: none"
fi
if [ -n "$SPECS_NEWER" ]; then
  out "specs_newer_on_base (sources changed on $BASE_REF after this branch left it; read the base version with git show $BASE_REF:<path>):"
  printf '%s\n' "$SPECS_NEWER" | sed 's/^/  /'
else
  out "specs_newer_on_base: none"
fi
out "tests_in_repo: ${TESTS_IN_REPO:-none found}"
if [ -n "$PREV" ]; then out "previous_review: $PREV ($OPEN_PREV numbered items)"; else out "previous_review: none"; fi
out "log_file: $LOG_FILE"
out "log_frontmatter (first lines of the log file, copy exactly):"
out "---"
out "branch: $BRANCH"
out "base: $BASE_SHOW"
out "head: $HEAD_SHA"
out "date: $(date '+%Y-%m-%d %H:%M')"
out "---"
if [ -n "$WARN" ]; then out "warnings:"; printf '%s' "$WARN"; else out "warnings: none"; fi
exit 0
