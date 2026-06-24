#!/usr/bin/env bash
#
# build-guide.sh — generate the multi-page "Guide" site from the single-source book.
#
# THE_EMBER_BOOK.md is the one canonical, hand-written source of truth. This tool splits it
# into one page per chapter under docs/guide/, wired for the Just the Docs theme (a left
# sidebar + search), and emits docs/llms-full.txt (the whole book as one clean Markdown file
# for language models to ingest in a single fetch).
#
# Run it with `make docs`. The docs/guide/ tree is GENERATED — never hand-edit it; edit the
# book and regenerate. The split is deterministic: same book in, same pages out.
#
# What it produces under docs/guide/:
#   index.md        the Guide landing (book preamble: the promise, "how to read", install)
#   part-1..6.md    one page per Part (a section node; auto-lists its chapters)
#   ch-01..25.md    one page per Chapter (the teaching content)
#   glossary.md     Appendix A
#   colophon.md     Colophon
#
# Front matter (title / parent / grand_parent / nav_order) is derived from the book's own
# "# Part .." and "## Chapter .." headings, so the sidebar mirrors the book's structure with
# zero manual bookkeeping. In-book "[Chapter N](#chapter-N--slug)" cross-links are rewritten
# to "/guide/ch-NN" so they keep working once the book is split across pages.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$ROOT/docs"
SRC="$DOCS/THE_EMBER_BOOK.md"
OUT="$DOCS/guide"
LLMS_FULL="$DOCS/llms-full.txt"

[ -f "$SRC" ] || { echo "build-guide: source not found: $SRC" >&2; exit 1; }

# Regenerate the generated tree from scratch every time (it is disposable build output).
rm -rf "$OUT"
mkdir -p "$OUT"

awk -v OUT="$OUT" '
# --- helpers ---------------------------------------------------------------

# Escape a string for use inside a YAML double-quoted scalar (only quotes need it here).
function esc(s) {
    gsub(/"/, "\\\"", s)
    return s
}





# Two-digit zero-padded chapter number, so ch-01..ch-09 sort before ch-10 in the sidebar.
function pad2(n) {
    n = n + 0
    return (n < 10 ? "0" n : "" n)
}





# Rewrite every in-book "](#chapter-N--anything)" anchor to the split-page URL "](/guide/ch-NN)".
# Handles multiple links on one line. Sub-anchors collapse to the page top, which is fine.
function rewrite_anchors(s,   out, pre, m, num) {
    out = ""
    while (match(s, /\]\(#chapter-[0-9]+--[^)]*\)/)) {
        pre = substr(s, 1, RSTART - 1)
        m   = substr(s, RSTART, RLENGTH)
        num = m
        sub(/^\]\(#chapter-/, "", num)
        sub(/--.*/, "", num)
        out = out pre "](/guide/ch-" pad2(num) ")"
        s = substr(s, RSTART + RLENGTH)
    }
    return out s
}





# Write the page that is currently buffered, then reset the buffer for the next page.
function flush(   i, fn, lo, hi) {
    if (page_kind == "") return
    fn = OUT "/" page_file

    printf("---\n") > fn
    printf("title: \"%s\"\n", esc(page_title)) > fn
    if (page_parent != "") printf("parent: \"%s\"\n", esc(page_parent)) > fn
    if (page_grand  != "") printf("grand_parent: \"%s\"\n", esc(page_grand)) > fn
    printf("nav_order: %d\n", page_nav) > fn
    if (page_haschildren) printf("has_children: true\n") > fn
    printf("---\n\n") > fn

    printf("# %s\n", page_h1) > fn

    if (page_kind == "part") {
        # A Part page has no prose of its own in the book; render a live list of its chapters.
        printf("\n{%% assign part_chapters = site.html_pages | where: \"parent\", page.title | sort: \"nav_order\" %%}\n") > fn
        printf("<ul class=\"part-chapters\">\n") > fn
        printf("{%% for ch in part_chapters %%}  <li><a href=\"{{ ch.url | relative_url }}\">{{ ch.title }}</a></li>\n") > fn
        printf("{%% endfor %%}</ul>\n") > fn
    } else {
        # Trim leading/trailing blank lines and stray horizontal rules left by the split.
        lo = 1
        while (lo <= nbuf && (buf[lo] == "---" || buf[lo] ~ /^[ \t]*$/)) lo++
        hi = nbuf
        while (hi >= lo && (buf[hi] == "---" || buf[hi] ~ /^[ \t]*$/)) hi--
        if (hi >= lo) {
            printf("\n") > fn
            for (i = lo; i <= hi; i++) print buf[i] > fn
        }
    }

    close(fn)
    delete buf
    nbuf = 0
    page_kind = ""
}





# Begin a new Part page (a section node under the Guide).
function startpart() {
    flush()
    part_num++
    chap_in_part = 0
    cur_part_title = substr($0, 3)
    page_kind = "part"
    page_file = "part-" part_num ".md"
    page_title = cur_part_title
    page_h1 = cur_part_title
    page_parent = "Guide"
    page_grand = ""
    page_nav = part_num
    page_haschildren = 1
    skip = 0
}





# Begin a new Chapter page (a grandchild of the Guide, under its Part).
function startchapter(   t, num) {
    flush()
    t = substr($0, 4)
    num = t
    sub(/^Chapter /, "", num)
    sub(/[^0-9].*/, "", num)
    chap_in_part++
    page_kind = "chapter"
    page_file = "ch-" pad2(num) ".md"
    page_title = t
    page_h1 = t
    page_parent = cur_part_title
    page_grand = "Guide"
    page_nav = chap_in_part
    page_haschildren = 0
    skip = 0
}





# Begin the Glossary appendix page (a child of the Guide, after the Parts).
function startappendix() {
    flush()
    page_kind = "appendix"
    page_file = "glossary.md"
    page_title = substr($0, 4)
    page_h1 = page_title
    page_parent = "Guide"
    page_grand = ""
    page_nav = 7
    page_haschildren = 0
    skip = 0
}





# Begin the Colophon page (a child of the Guide, last in the sidebar).
function startcolophon() {
    flush()
    page_kind = "colophon"
    page_file = "colophon.md"
    page_title = "Colophon"
    page_h1 = "Colophon"
    page_parent = "Guide"
    page_grand = ""
    page_nav = 8
    page_haschildren = 0
    skip = 0
}





# --- main ------------------------------------------------------------------

BEGIN {
    # The buffer starts as the Guide landing page; it absorbs the book preamble until Part I.
    page_kind = "index"
    page_file = "index.md"
    page_title = "Guide"
    page_h1 = "Ember by Firelight"
    page_parent = ""
    page_grand = ""
    page_nav = 2
    page_haschildren = 1
    nbuf = 0
    in_fence = 0
    in_src_fm = 0
    skip = 0
    part_num = 0
    chap_in_part = 0
    cur_part_title = ""
}

{
    # Strip the book source file own YAML front matter.
    if (in_src_fm) { if ($0 == "---") in_src_fm = 0; next }
    if (NR == 1 && $0 == "---") { in_src_fm = 1; next }

    # Fenced code blocks are opaque: keep their lines verbatim and never treat # as a heading.
    if ($0 ~ /^```/) { in_fence = 1 - in_fence; buf[++nbuf] = $0; next }
    if (in_fence)    { buf[++nbuf] = $0; next }

    # Page boundaries (only outside code fences).
    if ($0 ~ /^# Index/)      { skip = 1; next }   # the manual TOC; the sidebar replaces it
    if ($0 ~ /^# Part /)      { startpart();      next }
    if ($0 ~ /^## Chapter /)  { startchapter();   next }
    if ($0 ~ /^## Appendix /) { startappendix();  next }
    if ($0 ~ /^## Colophon/)  { startcolophon();  next }

    # The book title line becomes the landing page H1 (do not duplicate it in the body).
    if (page_kind == "index" && $0 ~ /^# Ember by Firelight/) { page_h1 = substr($0, 3); next }

    if (!skip) buf[++nbuf] = rewrite_anchors($0)
}

END {
    flush()
}
' "$SRC"

# llms-full.txt: the whole book as one clean Markdown file (its Jekyll front matter removed,
# in-book anchors left intact because here it really is one page). Near-free, high value for
# an LLM that wants to load the entire language in a single fetch.
awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---"    { infm = 0; next }
    infm                   { next }
                           { print }
' "$SRC" > "$LLMS_FULL"

# --- report ----------------------------------------------------------------

pages="$(find "$OUT" -name '*.md' | wc -l | tr -d ' ')"
echo "build-guide: wrote $pages pages to docs/guide/  +  docs/llms-full.txt"

stray="$(grep -rn '](#chapter' "$OUT" || true)"
if [ -n "$stray" ]; then
    echo "build-guide: WARNING — un-rewritten chapter anchors remain:" >&2
    echo "$stray" >&2
    exit 1
fi
