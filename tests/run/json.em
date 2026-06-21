// json.em — regression for std/json: parse → stringify round-trips, accessors, escapes, numbers,
// nesting, building, and error reporting. JSON braces/quotes are written as Ember `\{ \} \"` because
// `{ }` open interpolation and `"` closes a string in Ember source. (Accessor results are bound to
// locals before interpolating — Ember has no nested string literals inside `{ }`, and `{ }` takes a
// number or string, not a bool. Values are built through json's builder functions, not raw variants,
// since an imported enum's variants can't be constructed from another module.)
import "std/json" as json

fn show(label: string, p: Result<json.Json, string>) {
    match p {
        case Ok(v)    { println("{label}: {json.stringify(v)}") }
        case Err(msg) { println("{label}: ERR {msg}") }
    }
}


fn yn(b: bool) -> string {
    if b {
        return "true"
    }
    return "false"
}


fn main() -> int {
    // round-trips (compact serialization is canonical, so these double as round-trip checks)
    show("scalars", json.parse("[null, true, false, 42, -7, 3.14, 0.7]"))
    show("nested", json.parse("\{\"a\": [1, 2, \{\"b\": \"x\"\}], \"n\": null\}"))
    show("ws", json.parse("   \{  \"k\"  :  [ 1 , 2 , 3 ]  \}   "))

    // escapes: a JSON string carrying \" \n \t and BMP + astral \u escapes
    show("escapes", json.parse("\"quote=\\\" nl=\\n tab=\\t acute=\\u00e9 dash=\\u2014\""))

    // typed accessors over an object
    match json.parse("\{\"model\": \"opus\", \"max_tokens\": 2048, \"stream\": true, \"temp\": 0.7\}") {
        case Ok(v) {
            let model = json.as_str(json.get(v, "model"))
            let max_tokens = json.as_int(json.get(v, "max_tokens"))
            let temp = json.as_real(json.get(v, "temp"))
            let n = json.length(v)
            let stream = yn(json.as_bool(json.get(v, "stream")))
            let missing = yn(json.is_null(json.get(v, "absent")))
            println("model={model} max_tokens={max_tokens} temp={temp} stream={stream} missing={missing} len={n}")
        }
        case Err(m) { println("unexpected err {m}") }
    }

    // build a tree through the builder API, then serialize (escaping a quote + newline in a value)
    let built = json.obj([
        json.member("model", json.str("claude-opus-4-1")),
        json.member("max_tokens", json.num(2048)),
        json.member("stream", json.boolean(true)),
        json.member("messages", json.arr([
            json.obj([json.member("role", json.str("user")),
                      json.member("content", json.str("hi \"there\"\nbye"))])
        ]))
    ])
    println("built={json.stringify(built)}")

    // errors are reported, never crash
    show("e_trailing", json.parse("\{\} junk"))
    show("e_unterminated", json.parse("\"abc"))
    show("e_badcomma", json.parse("[1, 2,]"))
    show("e_empty", json.parse(""))
    show("e_badkey", json.parse("\{1: 2\}"))

    // number grammar is strict (adversarially found): these invalid forms are rejected, not coerced
    show("e_leadzero", json.parse("01"))
    show("e_traildot", json.parse("1."))
    show("e_expnodigit", json.parse("1e"))
    show("e_loneminus", json.parse("-"))
    show("e_dblexp", json.parse("1e2e3"))
    show("e_overrange", json.parse("1e400"))

    // unicode: a valid surrogate pair fuses to one scalar; an invalid low surrogate is rejected
    show("astral", json.parse("\"\\uD83D\\uDE00\""))
    show("e_badsurrogate", json.parse("\"\\uD83D\\u0041\""))

    // deep nesting fails cleanly instead of overflowing the call stack
    var deep: [string] = []
    var d = 0
    loop { if d == 200 { break } deep.append("[") d = d + 1 }
    d = 0
    loop { if d == 200 { break } deep.append("]") d = d + 1 }
    show("e_toodeep", json.parse(concat(deep)))
    return 0
}
