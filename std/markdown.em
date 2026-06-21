// std/markdown — parse Markdown (Claude's reply format) into a list of BLOCKS. The block model is an
// Ember `enum` (a sum type) so rendering is one exhaustive `match` — the language's own machinery doing
// exactly what it's for. Reusable by any Ember GUI: chat transcripts, docs viewers, note apps. This is
// the BLOCK level (paragraphs, blockquotes, fenced code, headings, bullets); inline spans (bold, `code`)
// are a follow-on. Pairs with std/highlight for colouring code blocks, and Flare's f.markdown to render.
import "std/string" as str

// A Markdown block. Render with `match`:
//   case Para(t)        -> wrapped prose
//   case Heading(n, t)  -> a title, size by level n
//   case Quote(t)       -> an indented, accent-barred quotation
//   case Code(lang, s)  -> a monospace panel, syntax-highlighted by `lang`
//   case Bullet(t)      -> a "• " list item
//   case Table(raw)     -> a pipe-table grid (raw = header + data rows, '\n'-joined; the `|---|` separator dropped)
enum Block {
    Para(text: string)
    Heading(level: int, text: string)
    Quote(text: string)
    Code(lang: string, src: string)
    Bullet(text: string)
    Table(raw: string)
}


// A styled inline SPAN within a block's prose — the inline level below Block. `inline()` splits a string
// into these and a rich-text renderer draws each in its own style. Markers: **bold**, *italic*/_italic_,
// `code`, [text](url); anything unmarked is Text. (Variants avoid Block's names — `Mono` not `Code` —
// because enum variants are module-scoped, OFI-073.) Reusable by any rich-text renderer; Flare's
// f.markdown drives it so Claude replies render with real emphasis instead of stripped markers.
enum Span {
    Text(s: string)
    Strong(s: string)
    Em(s: string)
    Mono(s: string)
    Link(text: string, url: string)
}


// _starts reports whether `line` begins with the ASCII prefix `pfx`.
fn _starts(line: string, pfx: string) -> bool {
    let n = str.cp_count(pfx)
    if str.cp_count(line) < n {
        return false
    }
    return str.cp_slice(line, 0, n) == pfx
}


// _drop returns `line` with its first `n` code points removed.
fn _drop(line: string, n: int) -> string {
    return str.cp_slice(line, n, str.cp_count(line))
}


// _flush commits the prose/quote accumulator `buf` as a Para or Quote block (nothing if empty).
fn _flush(blocks: [Block], buf: string, is_quote: bool) -> [Block] {
    var out = blocks
    if buf.len() > 0 {
        if is_quote {
            out.append(Quote(buf))
        } else {
            out.append(Para(buf))
        }
    }
    return out
}


// _heading_level counts the leading '#'s ("# " = 1 … "###### " = 6), 0 if not a heading.
fn _heading_level(line: string) -> int {
    var n = 0
    loop {
        if n >= str.cp_count(line) || str.cp_slice(line, n, n + 1) != "#" {
            break
        }
        n = n + 1
    }
    if n >= 1 && n <= 6 && str.cp_count(line) > n && str.cp_slice(line, n, n + 1) == " " {
        return n
    }
    return 0
}


// _ordered_len returns the length of an ordered-list marker ("1. ", "12. ") if `line` starts with one,
// else 0 — so each numbered item becomes its own block instead of being run together with its neighbours.
fn _ordered_len(line: string) -> int {
    let n = str.cp_count(line)
    var d = 0
    loop {
        if d >= n {
            break
        }
        let cc = char_code(str.cp_slice(line, d, d + 1))
        if cc >= 48 && cc <= 57 {
            d = d + 1
        } else {
            break
        }
    }
    if d == 0 {
        return 0
    }
    if d + 1 < n && str.cp_slice(line, d, d + 1) == "." && str.cp_slice(line, d + 1, d + 2) == " " {
        return d + 2
    }
    return 0
}


// _is_table_sep reports whether `line` is a Markdown table separator row — only '|', '-', ':' and spaces,
// with at least one '-' (e.g. "| --- | :--: |"). It marks the row under a table's header.
fn _is_table_sep(line: string) -> bool {
    let n = str.cp_count(line)
    if n == 0 {
        return false
    }
    var dash = false
    var ok = true
    var i = 0
    loop {
        if i == n {
            break
        }
        let c = str.cp_slice(line, i, i + 1)
        if c == "-" {
            dash = true
        } else if c != "|" && c != ":" && c != " " {
            ok = false
        }
        i = i + 1
    }
    return dash && ok
}


// parse turns Markdown text into blocks. Hard-wrapped prose/quote lines are joined into one logical
// paragraph (re-wrapped at render time); code-fence lines keep their exact layout. A blank line, a
// block-type change, or a fence flushes the current accumulator.
fn parse(text: string) -> [Block] {
    var blocks: [Block] = []
    let lines = text.split("\n")
    var buf = ""             // prose/quote accumulator
    var in_quote = false     // buf is a blockquote (vs prose)
    var i = 0
    loop {
        if i == lines.len() {
            break
        }
        let line = lines[i]
        let hl = _heading_level(line)
        if _starts(line, "```") {                              // fenced code block
            blocks = _flush(blocks, buf, in_quote)
            buf = ""
            let lang = _drop(line, 3)
            var src = ""
            var first = true
            i = i + 1
            loop {
                if i == lines.len() {
                    break
                }
                if _starts(lines[i], "```") {
                    i = i + 1                                  // consume the closing fence
                    break
                }
                if first {
                    src = lines[i]
                    first = false
                } else {
                    src = src + "\n" + lines[i]
                }
                i = i + 1
            }
            blocks.append(Code(lang, src))
        } else if line.len() == 0 {                            // blank line — flush
            blocks = _flush(blocks, buf, in_quote)
            buf = ""
            i = i + 1
        } else if hl > 0 {                                     // heading
            blocks = _flush(blocks, buf, in_quote)
            buf = ""
            blocks.append(Heading(hl, _drop(line, hl + 1)))
            i = i + 1
        } else if _starts(line, "- ") || _starts(line, "* ") { // bullet
            blocks = _flush(blocks, buf, in_quote)
            buf = ""
            blocks.append(Bullet(_drop(line, 2)))
            i = i + 1
        } else if _ordered_len(line) > 0 {                     // ordered list item ("1. …") — its own block
            blocks = _flush(blocks, buf, in_quote)
            buf = ""
            blocks.append(Bullet(_drop(line, _ordered_len(line))))
            i = i + 1
        } else if _starts(line, "> ") || line == ">" {         // blockquote line
            if buf.len() > 0 && !in_quote {
                blocks = _flush(blocks, buf, in_quote)
                buf = ""
            }
            in_quote = true
            let content = _drop(line, 1)                       // strip '>', keep one space then trimmed
            let c = str.cp_slice(content, 0, str.cp_count(content))
            if buf.len() == 0 {
                buf = _trim_lead(c)
            } else {
                buf = buf + " " + _trim_lead(c)
            }
            i = i + 1
        } else if _starts(line, "|") && i + 1 < lines.len() && _is_table_sep(lines[i + 1]) {   // a pipe table
            blocks = _flush(blocks, buf, in_quote)
            buf = ""
            var tbl = line                                     // the header row
            i = i + 2                                          // skip the header + the |---| separator row
            loop {
                if i == lines.len() {
                    break
                }
                if !_starts(lines[i], "|") {
                    break
                }
                tbl = tbl + "\n" + lines[i]
                i = i + 1
            }
            blocks.append(Table(tbl))
        } else {                                               // prose line
            if buf.len() > 0 && in_quote {
                blocks = _flush(blocks, buf, in_quote)
                buf = ""
            }
            in_quote = false
            if buf.len() == 0 {
                buf = line
            } else {
                buf = buf + " " + line
            }
            i = i + 1
        }
    }
    blocks = _flush(blocks, buf, in_quote)
    return blocks
}


// _trim_lead drops a single leading space (blockquote markers are "> x").
fn _trim_lead(s: string) -> string {
    if str.cp_count(s) > 0 && str.cp_slice(s, 0, 1) == " " {
        return _drop(s, 1)
    }
    return s
}


// _find_from returns the first code-point index >= `from` at which `needle` occurs in `text`, or -1.
fn _find_from(text: string, needle: string, from: int) -> int {
    let n = str.cp_count(text)
    let m = str.cp_count(needle)
    if m == 0 {
        return -1
    }
    var j = from
    loop {
        if j + m > n {
            break
        }
        if str.cp_slice(text, j, j + m) == needle {
            return j
        }
        j = j + 1
    }
    return -1
}


// inline splits prose into styled spans. It scans left to right; at each marker it flushes the pending
// plain text, emits the styled span, and resumes after it. An UNCLOSED marker is left as literal text
// (a lone `*` or backtick renders as itself), and a code span is literal inside (no nested markers).
// `**` is tested before `*` so bold wins over italic. Reusable: any rich-text renderer drives this.
fn inline(text: string) -> [Span] {
    var spans: [Span] = []
    let n = str.cp_count(text)
    var i = 0
    var buf = ""
    loop {
        if i >= n {
            break
        }
        let ch = str.cp_slice(text, i, i + 1)
        var matched = false

        if ch == "`" {                                              // `code`
            let close = _find_from(text, "`", i + 1)
            if close > i {
                if buf.len() > 0 {
                    spans.append(Text(buf))
                    buf = ""
                }
                spans.append(Mono(str.cp_slice(text, i + 1, close)))
                i = close + 1
                matched = true
            }
        } else if i + 2 <= n && str.cp_slice(text, i, i + 2) == "**" {   // **bold**
            let close = _find_from(text, "**", i + 2)
            if close > i + 1 {
                if buf.len() > 0 {
                    spans.append(Text(buf))
                    buf = ""
                }
                spans.append(Strong(str.cp_slice(text, i + 2, close)))
                i = close + 2
                matched = true
            }
        } else if ch == "*" || ch == "_" {                          // *italic* / _italic_
            let close = _find_from(text, ch, i + 1)
            if close > i {
                if buf.len() > 0 {
                    spans.append(Text(buf))
                    buf = ""
                }
                spans.append(Em(str.cp_slice(text, i + 1, close)))
                i = close + 1
                matched = true
            }
        } else if ch == "[" {                                       // [text](url)
            let rb = _find_from(text, "]", i + 1)
            if rb > i && rb + 2 <= n && str.cp_slice(text, rb + 1, rb + 2) == "(" {
                let rp = _find_from(text, ")", rb + 2)
                if rp > rb + 1 {
                    if buf.len() > 0 {
                        spans.append(Text(buf))
                        buf = ""
                    }
                    spans.append(Link(str.cp_slice(text, i + 1, rb), str.cp_slice(text, rb + 2, rp)))
                    i = rp + 1
                    matched = true
                }
            }
        }

        if !matched {
            buf = buf + ch
            i = i + 1
        }
    }
    if buf.len() > 0 {
        spans.append(Text(buf))
    }
    return spans
}
