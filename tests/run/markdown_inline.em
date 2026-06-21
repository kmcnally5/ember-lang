// tests/run/markdown_inline.em — regression for std/markdown.inline: splitting prose into styled spans
// (**bold**, *italic*/_italic_, `code`, [text](url)), collapsing nothing and leaving UNMATCHED markers
// literal. Pure (no graphics), so it locks the inline parser in the dependency-free suite.
import "std/markdown" as md


fn name(sp: md.Span) -> string {
    match sp {
        case Text(s)    { return "T<" + s + ">" }
        case Strong(s)  { return "B<" + s + ">" }
        case Em(s)      { return "I<" + s + ">" }
        case Mono(s)    { return "C<" + s + ">" }
        case Link(t, u) { return "L<" + t + "|" + u + ">" }
    }
    return "?"
}


fn dump(text: string) {
    let spans = md.inline(text)
    var out = ""
    var i = 0
    loop {
        if i == spans.len() {
            break
        }
        out = out + name(spans[i])
        i = i + 1
    }
    print(out)
}


fn main() -> int {
    dump("plain only")
    dump("a **bold** b")
    dump("x `code` y")
    dump("p *i* q _j_ r")
    dump("see [docs](http://x) ok")
    dump("**a** `b` *c* [d](e)")
    dump("lone * marker")
    return 0
}
