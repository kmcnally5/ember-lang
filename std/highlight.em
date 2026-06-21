// std/highlight — syntax highlighting as a LEXER that emits coloured spans instead of compiling. A
// code string becomes a flat list of Spans, each tagged with a Kind the renderer maps to a colour.
// On-thesis for an LLM-centred language whose chat output is full of code; reusable by any viewer. The
// tokeniser is a pragmatic C-family lexer (identifiers/keywords, numbers, strings, line + block
// comments) parameterised by a per-language keyword set — good enough to read at a glance, not a full
// grammar. Highlighting EMBER shares the language's own keyword vocabulary (kept in step with the
// compiler's lexical vocabulary).
import "std/string" as str

// What a span is: prose-plain text/punctuation, a language keyword, a string/char literal, a comment,
// a numeric literal, or a Capitalised type/constructor name.
enum Kind {
    Plain
    Keyword
    Str
    Comment
    Number
    Type
}

struct Span {
    text: string
    kind: Kind
}


fn _is_alpha(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95   // A-Z a-z _
}


fn _is_digit(c: int) -> bool {
    return c >= 48 && c <= 57
}


fn _is_alnum(c: int) -> bool {
    return _is_alpha(c) || _is_digit(c)
}


fn _is_upper(c: int) -> bool {
    return c >= 65 && c <= 90
}


// _in returns whether `w` is in the keyword list `kws`.
fn _in(kws: [string], w: string) -> bool {
    var i = 0
    loop {
        if i == kws.len() {
            return false
        }
        if kws[i] == w {
            return true
        }
        i = i + 1
    }
    return false
}


// _hash_comment: does `#` start a line comment in this language? (python/shell/ruby/yaml/toml, vs the
// C-family `//`). Both `//` and `/* */` are always recognised.
fn _hash_comment(lang: string) -> bool {
    return lang == "python" || lang == "py" || lang == "sh" || lang == "bash" ||
           lang == "shell" || lang == "ruby" || lang == "rb" || lang == "yaml" ||
           lang == "yml" || lang == "toml"
}


// keywords returns the keyword set for a language id (the fenced ```lang). Unknown languages get a broad
// C-family default so highlighting still reads sensibly.
fn keywords(lang: string) -> [string] {
    if lang == "ember" || lang == "em" {
        return ["fn", "let", "var", "struct", "enum", "match", "case", "if", "else",
                "loop", "while", "for", "in", "break", "return", "import", "extern",
                "mut", "move", "pub", "as", "spawn", "nursery", "requires", "ensures",
                "true", "false", "int", "bool", "string", "float", "Ptr",
                "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"]
    }
    if lang == "python" || lang == "py" {
        return ["def", "class", "return", "if", "elif", "else", "for", "while", "in",
                "import", "from", "as", "with", "try", "except", "finally", "raise",
                "lambda", "yield", "pass", "break", "continue", "and", "or", "not",
                "is", "None", "True", "False", "self", "async", "await", "global"]
    }
    if lang == "js" || lang == "ts" || lang == "javascript" || lang == "typescript" {
        return ["function", "const", "let", "var", "return", "if", "else", "for", "while",
                "of", "in", "class", "extends", "new", "import", "from", "export", "default",
                "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof",
                "true", "false", "null", "undefined", "this", "super", "interface", "type"]
    }
    if lang == "rust" || lang == "rs" {
        return ["fn", "let", "mut", "struct", "enum", "impl", "trait", "match", "if", "else",
                "loop", "while", "for", "in", "return", "use", "mod", "pub", "as", "ref",
                "move", "async", "await", "self", "Self", "true", "false", "where", "dyn"]
    }
    if lang == "go" {
        return ["func", "var", "const", "type", "struct", "interface", "map", "chan", "go",
                "return", "if", "else", "for", "range", "switch", "case", "default", "package",
                "import", "defer", "select", "true", "false", "nil"]
    }
    if lang == "c" || lang == "cpp" || lang == "c++" || lang == "h" {
        return ["int", "char", "void", "float", "double", "long", "short", "unsigned", "signed",
                "struct", "enum", "union", "typedef", "const", "static", "return", "if", "else",
                "for", "while", "do", "switch", "case", "break", "continue", "sizeof", "NULL"]
    }
    // a broad default
    return ["function", "fn", "def", "let", "var", "const", "class", "struct", "enum", "return",
            "if", "else", "for", "while", "import", "true", "false", "null"]
}


// spans tokenises `code` into coloured spans (covering every byte, whitespace included as Plain).
fn spans(lang: string, code: string) -> [Span] {
    var out: [Span] = []
    let cs = code.chars()
    let kws = keywords(lang)
    let hashc = _hash_comment(lang)
    var plain = ""
    var i = 0
    loop {
        if i == cs.len() {
            break
        }
        let c = cs[i]
        let cc = char_code(c)
        if _is_alpha(cc) {                                   // identifier or keyword or Type
            if plain.len() > 0 {
                out.append(Span { text: plain, kind: Plain })
                plain = ""
            }
            var word = ""
            loop {
                if i == cs.len() || !_is_alnum(char_code(cs[i])) {
                    break
                }
                word = word + cs[i]
                i = i + 1
            }
            if _in(kws, word) {
                out.append(Span { text: word, kind: Keyword })
            } else if _is_upper(char_code(str.cp_slice(word, 0, 1))) {
                out.append(Span { text: word, kind: Type })
            } else {
                out.append(Span { text: word, kind: Plain })
            }
        } else if _is_digit(cc) {                            // number
            if plain.len() > 0 {
                out.append(Span { text: plain, kind: Plain })
                plain = ""
            }
            var num = ""
            loop {
                if i == cs.len() {
                    break
                }
                let d = char_code(cs[i])
                if !_is_digit(d) && cs[i] != "." && !_is_alpha(d) {
                    break
                }
                num = num + cs[i]
                i = i + 1
            }
            out.append(Span { text: num, kind: Number })
        } else if c == "\"" || c == "'" || c == "`" {        // string / char literal
            if plain.len() > 0 {
                out.append(Span { text: plain, kind: Plain })
                plain = ""
            }
            let q = c
            var s = c
            i = i + 1
            loop {
                if i == cs.len() {
                    break
                }
                s = s + cs[i]
                if cs[i] == "\\" && i + 1 < cs.len() {       // skip the escaped char
                    s = s + cs[i + 1]
                    i = i + 2
                } else if cs[i] == q {
                    i = i + 1
                    break
                } else {
                    i = i + 1
                }
            }
            out.append(Span { text: s, kind: Str })
        } else if c == "/" && i + 1 < cs.len() && cs[i + 1] == "/" {   // // line comment
            if plain.len() > 0 {
                out.append(Span { text: plain, kind: Plain })
                plain = ""
            }
            var cm = ""
            loop {
                if i == cs.len() || cs[i] == "\n" {
                    break
                }
                cm = cm + cs[i]
                i = i + 1
            }
            out.append(Span { text: cm, kind: Comment })
        } else if c == "/" && i + 1 < cs.len() && cs[i + 1] == "*" {   // /* block comment */
            if plain.len() > 0 {
                out.append(Span { text: plain, kind: Plain })
                plain = ""
            }
            var cm = "/*"
            i = i + 2
            loop {
                if i == cs.len() {
                    break
                }
                if cs[i] == "*" && i + 1 < cs.len() && cs[i + 1] == "/" {
                    cm = cm + "*/"
                    i = i + 2
                    break
                }
                cm = cm + cs[i]
                i = i + 1
            }
            out.append(Span { text: cm, kind: Comment })
        } else if hashc && c == "#" {                                  // # line comment
            if plain.len() > 0 {
                out.append(Span { text: plain, kind: Plain })
                plain = ""
            }
            var cm = ""
            loop {
                if i == cs.len() || cs[i] == "\n" {
                    break
                }
                cm = cm + cs[i]
                i = i + 1
            }
            out.append(Span { text: cm, kind: Comment })
        } else {
            plain = plain + c
            i = i + 1
        }
    }
    if plain.len() > 0 {
        out.append(Span { text: plain, kind: Plain })
    }
    return out
}
