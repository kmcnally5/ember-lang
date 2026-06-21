// Regression for std/markdown — parsing Claude's reply format into the Block enum. Exercises heading,
// hard-wrapped prose joined into one paragraph, a multi-line blockquote, a fenced code block (language
// + preserved layout), and bullets. (Literal JSON/markdown braces aren't used here so no \{ escaping.)
import "std/markdown" as md

fn main() -> int {
    let src = "# Heading\nA paragraph explaining\nsomething across lines.\n> A quote from Claude\n> across two lines.\n\nSome code:\n```python\ndef hello():\n    print(\"hi\")\n```\n- first item\n- second item\n1. step one\n2. step two\n\n| Col A | Col B |\n| --- | --- |\n| x1 | y1 |"
    let blocks = md.parse(src)
    var i = 0
    loop {
        if i == blocks.len() {
            break
        }
        match blocks[i] {
            case Para(t)       { println("PARA: {t}") }
            case Heading(n, t) { println("H{n}: {t}") }
            case Quote(t)      { println("QUOTE: {t}") }
            case Code(l, s)    { println("CODE[{l}]: {s}") }
            case Bullet(t)     { println("BULLET: {t}") }
            case Table(r)      { println("TABLE: {r}") }
        }
        i = i + 1
    }
    return 0
}
