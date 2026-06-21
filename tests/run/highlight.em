// Regression for std/highlight — the lexer-as-highlighter. Tags Python and Ember snippets and prints
// each span's kind so a regression in keyword sets / string / comment / number scanning shows up.
import "std/highlight" as hl

fn kname(k: hl.Kind) -> string {
    match k {
        case Plain   { return "." }
        case Keyword { return "K" }
        case Str     { return "S" }
        case Comment { return "C" }
        case Number  { return "N" }
        case Type    { return "T" }
    }
    return "?"
}

fn dump(lang: string, code: string) {
    println("--- {lang} ---")
    let sp = hl.spans(lang, code)
    var i = 0
    loop {
        if i == sp.len() {
            break
        }
        print("{kname(sp[i].kind)}[{sp[i].text}]")
        i = i + 1
    }
    println("")
}

fn main() -> int {
    dump("python", "x = add(1, 2)  # call\nreturn \"ok\"")
    dump("ember", "fn f() -> int \{ let n: Ptr = g() \}")
    return 0
}
