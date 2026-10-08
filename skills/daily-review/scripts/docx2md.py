#!/usr/bin/env python3
"""Convert a .docx plan into navigable Markdown (stdlib only).

Keeps what a code reviewer needs: real Markdown headings from Word heading
styles (so sections can be grepped), lists, and tables as pipe tables.
Drops images and formatting.

Usage: python3 docx2md.py <input.docx> <output.md>
Also writes <output>.index.md: every heading with its line number.
"""
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def heading_level(p, styles):
    ppr = p.find(W + "pPr")
    if ppr is None:
        return 0
    lvl = ppr.find(W + "outlineLvl")
    if lvl is not None:
        try:
            v = int(lvl.get(W + "val"))
            if 0 <= v <= 5:
                return v + 1
        except (TypeError, ValueError):
            pass
    st = ppr.find(W + "pStyle")
    if st is None:
        return 0
    sid = st.get(W + "val") or ""
    name = styles.get(sid, sid).lower().replace(" ", "")
    if name == "title":
        return 1
    m = re.match(r"heading(\d)$", name) or re.match(r"heading(\d)$", sid.lower())
    return int(m.group(1)) if m else 0


def is_list(p):
    ppr = p.find(W + "pPr")
    if ppr is None:
        return False
    if ppr.find(W + "numPr") is not None:
        return True
    st = ppr.find(W + "pStyle")
    return st is not None and "list" in (st.get(W + "val") or "").lower()


def para_text(p):
    out = []
    for el in p.iter():
        if el.tag == W + "t" and el.text:
            out.append(el.text)
        elif el.tag == W + "tab":
            out.append(" ")
        elif el.tag in (W + "br", W + "cr"):
            out.append(" ")
    return re.sub(r"[  ]+", " ", "".join(out)).strip()


def cell_text(tc):
    parts = [para_text(p) for p in tc.iter(W + "p")]
    return " / ".join(x for x in parts if x).replace("|", "\\|")


def table_md(tbl):
    rows = []
    for tr in tbl.findall(W + "tr"):
        cells = []
        for tc in tr.findall(W + "tc"):
            span = 1
            tcpr = tc.find(W + "tcPr")
            if tcpr is not None and tcpr.find(W + "gridSpan") is not None:
                try:
                    span = int(tcpr.find(W + "gridSpan").get(W + "val"))
                except (TypeError, ValueError):
                    span = 1
            cells.append(cell_text(tc))
            cells.extend([""] * (span - 1))
        if any(cells):
            rows.append(cells)
    if not rows:
        return []
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    lines = ["| " + " | ".join(rows[0]) + " |", "|" + " --- |" * width]
    lines += ["| " + " | ".join(r) + " |" for r in rows[1:]]
    return lines


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: docx2md.py <input.docx> <output.md>")
    src, dst = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(src) as z:
        doc = ET.fromstring(z.read("word/document.xml"))
        styles = {}
        if "word/styles.xml" in z.namelist():
            for s in ET.fromstring(z.read("word/styles.xml")).iter(W + "style"):
                n = s.find(W + "name")
                if n is not None:
                    styles.setdefault(s.get(W + "styleId"), n.get(W + "val") or "")
    body = doc.find(W + "body")
    out, index = [], []
    for el in list(body):
        if el.tag == W + "p":
            text = para_text(el)
            if not text:
                continue
            lvl = heading_level(el, styles)
            if lvl:
                out.append("")
                out.append("#" * lvl + " " + text)
                index.append((len(out), lvl, text))
                out.append("")
            elif is_list(el):
                out.append("- " + text)
            else:
                out.append(text)
                out.append("")
        elif el.tag == W + "tbl":
            out.append("")
            out.extend(table_md(el))
            out.append("")
    md = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip() + "\n"
    with open(dst, "w", encoding="utf-8") as f:
        f.write(md)
    # Recompute line numbers on the final text for the index.
    idx_lines = []
    for n, line in enumerate(md.splitlines(), 1):
        m = re.match(r"^(#{1,6}) (.*)", line)
        if m:
            idx_lines.append("%s- L%d %s" % ("  " * (len(m.group(1)) - 1), n, m.group(2)))
    with open(re.sub(r"\.md$", "", dst) + ".index.md", "w", encoding="utf-8") as f:
        f.write("# Section index for %s\n\n" % dst.split("/")[-1])
        f.write("\n".join(idx_lines) + "\n")
    print("wrote %s (%d lines, %d headings)" % (dst, md.count("\n"), len(idx_lines)))


if __name__ == "__main__":
    main()
