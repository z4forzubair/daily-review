#!/usr/bin/env python3
"""review-pr: turn a review draft into a pending GitHub review.

Usage:
  post_review.py DRAFT [--dry-run] [--replace-pending]
  post_review.py --ranges --info PR_JSON     print the lines that inline comments can go on

DRAFT is the .github.md file that the review-pr skill writes next to the review log:

    # Summary
    The review's top-level text.

    # Comments
    ## src/api/discounts.py:12
    One inline comment, in Markdown.

    ## src/api/discounts.py:20-24
    A comment on several lines. A ```suggestion block replaces exactly these lines.

Inline comments can only go on lines of the PR's diff (the new side, as GitHub shows it,
with three lines of context). A comment partly outside a diff hunk is shrunk to the part
inside, and its suggestion becomes a plain code block. A comment with no line in the diff,
or on a file the PR doesn't change, moves to the summary with a link to the line.

The review is created PENDING: nobody else sees it until you submit it on GitHub. This
script never submits, approves or requests changes; that stays your click.

The PR details come from pr.json, which pr.sh saves in .reviews/.work/pr-<n>/. The commit
the comments attach to is the "head:" of the review log next to the draft.

Exit codes: 0 done or nothing to post, 1 error, 2 bad draft or arguments,
3 you already have a pending review on this PR (rerun with --replace-pending to delete it).
Needs git and, unless --dry-run, the GitHub CLI (gh). Python 3.6+, standard library only.
"""
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import quote

MAX_BODY = 65000  # GitHub rejects comment bodies over 65536 characters


def die(msg, code=1):
    print("status: error")
    print("error: " + msg)
    sys.exit(code)


# ---------------------------------------------------------------- git and the PR diff

def git(args, cwd):
    r = subprocess.run(["git"] + args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def c_unquote(s):
    """Undo git's C-style quoting of a path, for example "b/a\\"b" -> b/a"b."""
    if not (len(s) >= 2 and s[0] == '"' and s[-1] == '"'):
        return s
    s, out, i = s[1:-1], bytearray(), 0
    simple = {"n": 10, "t": 9, "r": 13, '"': 34, "\\": 92, "a": 7, "b": 8, "f": 12, "v": 11}
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt in simple:
                out.append(simple[nxt]); i += 2; continue
            if re.match(r"[0-7]{3}", s[i + 1:i + 4]):
                out.append(int(s[i + 1:i + 4], 8)); i += 4; continue
        out.extend(ch.encode("utf-8")); i += 1
    return out.decode("utf-8", "replace")


class FileDiff:
    def __init__(self):
        self.hunks = []      # [start, end] ranges of new-side lines shown in the diff
        self.added = set()   # new-side lines added or changed by the PR


def pr_diff(cwd, base, head):
    """Files of the PR (new paths) -> FileDiff, from git's diff with GitHub's three lines of context."""
    rc, names, err = git(["-c", "core.quotePath=false", "-c", "diff.relative=false", "diff", "--name-only", "-z", "-M", base, head], cwd)
    if rc != 0:
        die("git could not compare %s and %s: %s" % (base[:7], head[:7], err.strip()))
    files = {n: FileDiff() for n in names.split("\0") if n}
    rc, text, err = git(["-c", "core.quotePath=false", "-c", "diff.relative=false", "diff", "--no-color", "--no-ext-diff",
                         "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "--diff-algorithm=myers",
                         "-M", "-U3", base, head], cwd)
    if rc != 0:
        die("git diff failed: " + err.strip())
    cur, old_left, new_left, new_no = None, 0, 0, 0
    for line in text.split("\n"):
        if old_left > 0 or new_left > 0:
            tag = line[:1]
            if tag == " ":
                new_no += 1; old_left -= 1; new_left -= 1
            elif tag == "+":
                new_no += 1; new_left -= 1
                if cur is not None:
                    cur.added.add(new_no)
            elif tag == "-":
                old_left -= 1
            continue
        if line.startswith("diff --git "):
            cur = None
        elif line.startswith("+++ "):
            name = line[4:].rstrip("\t")
            name = c_unquote(name)
            if name == "/dev/null":
                cur = None
            else:
                name = name[2:] if name.startswith("b/") else name
                cur = files.setdefault(name, FileDiff())
        elif line.startswith("@@ "):
            m = re.match(r"@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
            if not m:
                continue
            old_left = int(m.group(1)) if m.group(1) is not None else 1
            start = int(m.group(2))
            new_left = int(m.group(3)) if m.group(3) is not None else 1
            new_no = start - 1
            if cur is not None and new_left > 0:
                cur.hunks.append([start, start + new_left - 1])
    return files


def ranges_text(nums):
    nums, out = sorted(nums), []
    for n in nums:
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return ", ".join(str(a) if a == b else "%d-%d" % (a, b) for a, b in out)


# ---------------------------------------------------------------- the draft

LOC_RE = re.compile(r"^##\s+`?(?P<path>[^`]+?)`?\s*(?::|\s+lines?\s+)\s*L?(?P<start>\d+)"
                    r"(?:\s*(?:-|\u2013|\.\.)\s*L?(?P<end>\d+))?\s*$", re.I)
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
SUGGESTION_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})[ \t]*suggestion\b[ \t]*(.*)$", re.I)


def parse_draft(text):
    text = text.replace("\r\n", "\n")
    text = re.sub(r"\A\s*<!--.*?-->\s*", "", text, flags=re.S)  # a leading note for whoever edits the draft
    summary, comments, section, fence, current = [], [], "summary", None, None
    for no, line in enumerate(text.split("\n"), 1):
        if fence is None:
            m = FENCE_RE.match(line)
            if m:
                fence = m.group(1)
        else:
            if re.match(r"^ {0,3}" + re.escape(fence[0]) + "{%d,}\\s*$" % len(fence), line):
                fence = None
            (current["body"] if current else summary).append(line)
            continue
        if re.match(r"^#\s+summary\s*$", line, re.I) and section == "summary" and not comments:
            continue
        if re.match(r"^#{1,2}\s+(inline\s+)?comments\s*:?\s*$", line, re.I):
            section = "comments"; current = None; continue
        if line.startswith("## "):
            m = LOC_RE.match(line.rstrip())
            if m:
                s, e = int(m.group("start")), int(m.group("end") or m.group("start"))
                current = {"path": m.group("path").strip(), "start": min(s, e), "end": max(s, e), "line_no": no, "body": []}
                comments.append(current)
                section = "comments"
                continue
            if section == "comments":
                die("draft line %d: '%s' should be '## <path>:<line>' or '## <path>:<first>-<last>'" % (no, line.strip()), 2)
        if section == "comments" and current is None:
            if line.strip():
                die("draft line %d: text under '# Comments' must come after a '## <path>:<line>' heading" % no, 2)
            continue
        (current["body"] if current else summary).append(line)
    for c in comments:
        c["body"] = "\n".join(c["body"]).strip()
        if not c["body"]:
            die("draft line %d: the comment on %s:%d has no text" % (c["line_no"], c["path"], c["end"]), 2)
        m = re.search(r"#(\d+)\b", c["body"].split("\n", 1)[0])
        c["label"] = "#" + m.group(1) if m else "comment at draft line %d" % c["line_no"]
    return "\n".join(summary).strip(), comments


def neutralize(body):
    lines, n = body.split("\n"), 0
    for i, line in enumerate(lines):
        m = SUGGESTION_RE.match(line)
        if m:
            lines[i] = m.group(1) + m.group(2) + m.group(3)
            n += 1
    return "\n".join(lines), n


def read_head(log_path):
    try:
        lines = open(log_path, encoding="utf-8").read().split("\n")
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:40]:
        if line.strip() == "---":
            break
        m = re.match(r"\s*head:\s*([0-9a-f]{7,40})\s*$", line)
        if m:
            return m.group(1)
    return None


# ---------------------------------------------------------------- placing the comments

def place(comments, files, info, head):
    inline, moved, adjusted = [], [], []
    prefixes = [p.rstrip("/") + "/" for p in (info.get("tree"), info.get("checkout")) if p]
    if info.get("tree") and info.get("checkout"):
        prefixes.append(os.path.relpath(info["tree"], info["checkout"]) + "/")
    for c in comments:
        path = c["path"]
        for p in prefixes:
            if path.startswith(p):
                path = path[len(p):]
        path = path[2:] if path.startswith("./") else path
        if path not in files and path[:2] in ("a/", "b/") and path[2:] in files:
            path = path[2:]
        c["path"] = path
        s, e = c["start"], c["end"]
        fd = files.get(path)
        if fd is None:
            moved.append((c, "this PR doesn't change %s" % path)); continue
        if not fd.hunks:
            moved.append((c, "GitHub shows no diff lines for %s (binary, deleted or only renamed)" % path)); continue
        over = [h for h in fd.hunks if h[0] <= e and h[1] >= s]
        if not over:
            moved.append((c, "%s:%s is outside the PR's diff, which shows lines %s of this file"
                          % (path, s if s == e else "%d-%d" % (s, e), ", ".join("%d-%d" % tuple(h) for h in fd.hunks))))
            continue
        h = max(over, key=lambda h: (min(e, h[1]) - max(s, h[0]), h[0] <= e <= h[1]))
        s2, e2 = max(s, h[0]), min(e, h[1])
        body = c["body"]
        if (s2, e2) != (s, e):
            body, n = neutralize(body)
            adjusted.append((c, "%d-%d -> %s%s" % (s, e, s2 if s2 == e2 else "%d-%d" % (s2, e2),
                                                    "; its suggestion became a plain code block" if n else "")))
        item = {"path": path, "line": e2, "side": "RIGHT", "body": body}
        if s2 < e2:
            item["start_line"], item["start_side"] = s2, "RIGHT"
        item["_added_only"] = all(n in fd.added for n in (s2, e2))
        item["_src"] = c
        inline.append(item)
    return inline, moved, adjusted


def line_link(info, head, path, s, e):
    url = "https://%s/%s/blob/%s/%s#L%d" % (info["host"], info["repo"], head, quote(path), s)
    return url + ("-L%d" % e if e != s else "")


def build_body(summary, moved_items, info, head):
    parts = [summary] if summary else []
    if moved_items:
        parts.append("**Comments on lines outside this PR's diff**")
        for c, _why in moved_items:
            where = c["path"] + ":" + (str(c["start"]) if c["start"] == c["end"] else "%d-%d" % (c["start"], c["end"]))
            body, _ = neutralize(c["body"])
            parts.append("[`%s`](%s)\n%s" % (where, line_link(info, head, c["path"], c["start"], c["end"]), body))
    return "\n\n".join(parts).strip()


# ---------------------------------------------------------------- GitHub, through gh

class GH:
    def __init__(self, host):
        self.host = host

    def call(self, args, data=None):
        try:
            r = subprocess.run(["gh", "api", "--hostname", self.host] + args, input=data.encode("utf-8") if data else None,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError:
            die("the GitHub CLI (gh) is not installed. Install it from https://cli.github.com, then run: gh auth login")
        return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")

    @staticmethod
    def parse(text):
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
            out.append(obj)
        return out

    @classmethod
    def error_text(cls, out, err):
        msgs = []
        for obj in cls.parse(out):
            if isinstance(obj, dict):
                if obj.get("message"):
                    msgs.append(str(obj["message"]))
                for e in obj.get("errors") or []:
                    msgs.append(e.get("message", json.dumps(e)) if isinstance(e, dict) else str(e))
        msgs.append(" ".join(err.split()))
        return "; ".join(m for m in msgs if m)

    def get(self, path, paginate=False):
        rc, out, err = self.call((["--paginate"] if paginate else []) + [path])
        if rc != 0:
            text = self.error_text(out, err)
            hint = ""
            if "401" in text or "Bad credentials" in text:
                hint = " (gh is not logged in: run gh auth login)"
            elif "404" in text or "Not Found" in text:
                hint = " (check that gh is logged in as an account that can see %s)" % path.split("/pulls")[0]
            die("GitHub request %s failed: %s%s" % (path, text, hint))
        objs = self.parse(out)
        if paginate:
            items = []
            for o in objs:
                items.extend(o if isinstance(o, list) else [o])
            return items
        return objs[0] if objs else {}


def pending_reviews(gh, info, me):
    reviews = gh.get("repos/%s/pulls/%d/reviews" % (info["repo"], info["number"]), paginate=True)
    return [r for r in reviews if isinstance(r, dict) and r.get("state") == "PENDING"
            and (r.get("user") or {}).get("login", me) == me]


# ---------------------------------------------------------------- main

def main(argv):
    args = {"dry": False, "replace": False, "ranges": False, "info": None, "draft": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            args["dry"] = True
        elif a == "--replace-pending":
            args["replace"] = True
        elif a == "--ranges":
            args["ranges"] = True
        elif a == "--info" and i + 1 < len(argv):
            args["info"] = argv[i + 1]; i += 1
        elif a.startswith("-"):
            die("unknown option %s" % a, 2)
        elif args["draft"] is None:
            args["draft"] = a
        i += 1

    draft = args["draft"]
    info_path = args["info"]
    if not info_path:
        if not draft:
            die("give the draft file, for example: post_review.py .reviews/pr-12/review-1-2026-10-29_1830.github.md", 2)
        d = os.path.dirname(os.path.abspath(draft))
        info_path = os.path.join(os.path.dirname(d), ".work", os.path.basename(d), "pr.json")
    try:
        info = json.load(open(info_path, encoding="utf-8"))
    except (OSError, ValueError):
        die("cannot read the PR details in %s; run pr.sh for this PR first" % info_path, 2)
    cwd = info.get("tree") if os.path.isdir(info.get("tree") or "") else info.get("checkout")
    if not cwd or not os.path.isdir(cwd):
        die("cannot find the PR's checkout (%s); run pr.sh for this PR again" % info.get("tree"), 2)

    if args["ranges"]:
        files = pr_diff(cwd, info["merge_base"], info["head_sha"])
        print("# Lines of PR #%d that inline comments can go on (new line numbers; + marks lines the PR adds or changes)."
              % info["number"])
        none = []
        for path in sorted(files):
            fd = files[path]
            if fd.hunks:
                print("%s: %s (+ %s)" % (path, ", ".join("%d-%d" % tuple(h) for h in fd.hunks), ranges_text(fd.added) or "none"))
            else:
                none.append(path)
        if none:
            print("# Changed, but no lines to comment on (binary, deleted or only renamed): " + ", ".join(none))
        return 0

    if not draft or not os.path.isfile(draft):
        die("cannot find the draft %s" % draft, 2)
    summary, comments = parse_draft(open(draft, encoding="utf-8").read())

    warnings = []
    head = None
    if draft.endswith(".github.md"):
        head = read_head(draft[:-len(".github.md")] + ".md")
    if not head:
        head = info["head_sha"]
        warnings.append("could not read 'head:' from the review log next to the draft; using the PR head %s" % head[:7])
    rc, full, _ = git(["rev-parse", "--verify", "-q", head + "^{commit}"], cwd)
    if rc != 0:
        die("the reviewed commit %s is not in this repository; run pr.sh for this PR again" % head, 2)
    head = full.strip()
    rc, mb, _ = git(["merge-base", info["base_ref"], head], cwd)
    base = mb.strip() if rc == 0 and mb.strip() else info["merge_base"]

    files = pr_diff(cwd, base, head)
    inline, moved, adjusted = place(comments, files, info, head)
    body = build_body(summary, moved, info, head)
    if len(body) > MAX_BODY:
        die("the summary is %d characters; GitHub's limit is about 65,000. Shorten the draft's summary." % len(body), 2)
    for c in inline:
        if len(c["body"]) > MAX_BODY:
            die("the comment %s is too long for GitHub; shorten it" % c["_src"]["label"], 2)

    def payload_for(items, extra_moved):
        b = build_body(summary, moved + extra_moved, info, head)
        p = {"commit_id": head, "body": b, "comments": [{k: v for k, v in c.items() if not k.startswith("_")} for c in items]}
        if not p["body"]:
            del p["body"]
        return p

    payload = payload_for(inline, [])
    work = os.path.dirname(os.path.abspath(info_path))
    payload_path = os.path.join(work, os.path.basename(draft)[:-3] + ".payload.json")
    posted_path = os.path.join(work, os.path.basename(draft)[:-3] + ".posted.json")
    try:
        with open(payload_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=1, ensure_ascii=False)
    except OSError:
        payload_path = "(not saved)"

    def report(status, url=None, n_inline=None, extra=None):
        print("status: " + status)
        if url:
            print("review: " + url)
            print("  Pending: only you can see it. Open the PR's Files changed tab, read the comments, then submit the review there (Comment, Approve or Request changes).")
        print("reviewed_commit: %s (%s)" % (head[:7], info.get("head_branch", "")))
        print("inline_comments: %d" % (len(inline) if n_inline is None else n_inline))
        all_moved = moved + (extra or [])
        print("moved_to_summary: %d" % len(all_moved))
        for c, why in all_moved:
            print("  %s: %s" % (c["label"], why))
        print("adjusted: %d" % len(adjusted))
        for c, how in adjusted:
            print("  %s %s:%s" % (c["label"], c["path"], how))
        if warnings:
            print("warnings:")
            for w in warnings:
                print("  - " + w)
        else:
            print("warnings: none")
        print("payload: " + payload_path)

    if not payload.get("comments") and not payload.get("body"):
        print("status: nothing-to-post")
        print("The draft has no summary and no comments.")
        return 0

    if args["dry"]:
        report("dry-run (nothing was sent to GitHub)")
        return 0

    gh = GH(info["host"])
    me = (gh.get("user") or {}).get("login")
    if not me:
        die("could not read your GitHub login from gh; run gh auth status")
    pr = gh.get("repos/%s/pulls/%d" % (info["repo"], info["number"]))
    now = ((pr.get("head") or {}).get("sha")) or ""
    if now and now != head:
        warnings.append("the PR has new commits since this review (head is now %s). The comments attach to the reviewed commit %s; "
                        "GitHub marks a comment outdated where a later commit changed its lines." % (now[:7], head[:7]))
    if pr.get("merged"):
        warnings.append("the PR is already merged")

    mine = pending_reviews(gh, info, me)
    if mine:
        if not args["replace"]:
            n = len(gh.get("repos/%s/pulls/%d/reviews/%s/comments" % (info["repo"], info["number"], mine[0]["id"]), paginate=True))
            print("status: pending-review-exists")
            print("error: @%s already has a pending review on PR #%d with %d inline comment(s), not submitted yet. "
                  "GitHub allows one pending review per person. Submit or discard it on the PR's Files changed tab, "
                  "or rerun with --replace-pending to delete it and post this one instead." % (me, info["number"], n))
            return 3
        for r in mine:
            n = len(gh.get("repos/%s/pulls/%d/reviews/%s/comments" % (info["repo"], info["number"], r["id"]), paginate=True))
            rc, out, err = gh.call(["--method", "DELETE", "repos/%s/pulls/%d/reviews/%s" % (info["repo"], info["number"], r["id"])])
            if rc != 0:
                die("could not delete your pending review %s: %s" % (r["id"], GH.error_text(out, err)))
            warnings.append("deleted your earlier pending review, which had %d inline comment(s)" % n)

    # Try with every comment inline; if GitHub refuses the placements, keep only comments on
    # added lines; if it still refuses, move every comment into the summary.
    attempts = [(inline, [])]
    added = [c for c in inline if c["_added_only"]]
    if 0 < len(added) < len(inline):
        attempts.append((added, [(c["_src"], "GitHub refused its line; moved to the summary")
                                 for c in inline if not c["_added_only"]]))
    if inline:
        attempts.append(([], [(c["_src"], "GitHub refused the inline comments; moved to the summary") for c in inline]))
    last_error = ""
    for n_try, (items, extra) in enumerate(attempts):
        p = payload_for(items, extra)
        rc, out, err = gh.call(["--method", "POST", "repos/%s/pulls/%d/reviews" % (info["repo"], info["number"]), "--input", "-"],
                               json.dumps(p))
        if rc == 0:
            review = (GH.parse(out) or [{}])[0]
            if n_try:
                warnings.append("GitHub refused the first attempt (%s)" % last_error)
                with open(payload_path, "w", encoding="utf-8") as f:
                    json.dump(p, f, indent=1, ensure_ascii=False)
            if review.get("state") not in (None, "PENDING"):
                warnings.append("GitHub created the review as %s instead of pending" % review.get("state"))
            url = "%s/files" % info["url"] if info.get("url") else review.get("html_url")
            try:
                with open(posted_path, "w", encoding="utf-8") as f:
                    json.dump({"review_id": review.get("id"), "url": url, "commit": head,
                               "at": time.strftime("%Y-%m-%d %H:%M"), "inline_comments": len(items),
                               "moved_to_summary": len(moved) + len(extra)}, f, indent=1)
            except OSError:
                pass
            report("posted", url, len(items), extra)
            return 0
        last_error = GH.error_text(out, err)
        low = last_error.lower()
        if "pending review" in low:
            print("status: pending-review-exists")
            print("error: GitHub says you already have a pending review on PR #%d (%s). Submit or discard it on GitHub, "
                  "or rerun with --replace-pending." % (info["number"], last_error))
            return 3
        if not ("422" in last_error or "unprocessable" in low or "diff" in low or "line" in low):
            die("GitHub refused the review: %s" % last_error)
        # A refused request should create nothing, but make sure no half-made pending review is left behind.
        for r in pending_reviews(gh, info, me):
            gh.call(["--method", "DELETE", "repos/%s/pulls/%d/reviews/%s" % (info["repo"], info["number"], r["id"])])
    die("GitHub refused the review: %s" % last_error)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
