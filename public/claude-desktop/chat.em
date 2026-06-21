// chat.em — a CLI that talks to Claude over HTTPS (Phase 1 of the Claude Desktop app).
//
// Ember has no networking; it borrows libcurl through the FFI, wrapped as the reusable `std/http`
// transport (http.post — a blocking request, the whole response body at once). Everything else
// (building the Messages-API JSON request, escaping the user's text, parsing the response) is pure
// Ember. JSON braces are written `\{` `\}` because `{...}` is string interpolation in Ember.
//
//   make net
//   export ANTHROPIC_API_KEY=sk-ant-...
//   build/emberc-net --emit=run public/claude-desktop/chat.em "your message"

import "std/http" as http






// hex_digit renders 0..15 as the ASCII char '0'..'9' / 'a'..'f'.
fn hex_digit(n: int) -> string {
    if n < 10 {
        return from_char_code(48 + n)
    }
    return from_char_code(97 + (n - 10))
}






// hex_val reads one hex character ('0'..'9','a'..'f','A'..'F') back to 0..15 (-1 if not hex).
fn hex_val(c: string) -> int {
    let k = char_code(c)
    if k >= 48 && k <= 57 {
        return k - 48
    }
    if k >= 97 && k <= 102 {
        return k - 97 + 10
    }
    if k >= 65 && k <= 70 {
        return k - 65 + 10
    }
    return 0
}






// json_escape escapes a string so it can sit inside a JSON double-quoted value: the structural
// characters `"` and `\`, the common control escapes, and any other control byte as `\u00XX`.
fn json_escape(s: string) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() {
            return concat(out)
        }
        let c = cs[i]
        let code = char_code(c)
        if c == "\"" {
            out.append("\\\"")
        } else if c == "\\" {
            out.append("\\\\")
        } else if code == 10 {
            out.append("\\n")
        } else if code == 13 {
            out.append("\\r")
        } else if code == 9 {
            out.append("\\t")
        } else if code < 32 {
            out.append("\\u00" + hex_digit(code / 16) + hex_digit(code))
        } else {
            out.append(c)
        }
        i = i + 1
    }
    return concat(out)
}






// build_request assembles the Anthropic Messages-API request body for a single user turn. The
// `\{`/`\}`/`\"` are literal JSON; `{model}`/`{max_tokens}`/`{esc}` are Ember interpolation holes.
fn build_request(model: string, max_tokens: int, user_msg: string) -> string {
    let esc = json_escape(user_msg)
    return "\{\"model\":\"{model}\",\"max_tokens\":{max_tokens},\"messages\":[\{\"role\":\"user\",\"content\":\"{esc}\"\}]\}"
}






// extract_text pulls the assistant's text out of the JSON response. The Messages API returns
// `…"content":[{"type":"text","text":"<reply>"}]…`, so we split on the `"text":"` key and decode
// the JSON string value that follows (its escapes, up to the closing unescaped quote). Returns the
// empty string if there is no text block (e.g. an API error response).
fn extract_text(resp: string) -> string {
    let parts = resp.split("\"text\":\"")
    if parts.len() < 2 {
        return ""
    }
    let cs = parts[1].chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() {
            return concat(out)
        }
        let c = cs[i]
        if c == "\\" {
            i = i + 1
            if i == cs.len() {
                return concat(out)
            }
            let e = cs[i]
            if e == "n" {
                out.append(from_char_code(10))
            } else if e == "t" {
                out.append(from_char_code(9))
            } else if e == "r" {
                out.append(from_char_code(13))
            } else if e == "\"" {
                out.append("\"")
            } else if e == "\\" {
                out.append("\\")
            } else if e == "/" {
                out.append("/")
            } else if e == "u" && i + 4 < cs.len() {
                let cp = hex_val(cs[i + 1]) * 4096 + hex_val(cs[i + 2]) * 256 +
                         hex_val(cs[i + 3]) * 16 + hex_val(cs[i + 4])
                out.append(from_char_code(cp))
                i = i + 4
            } else {
                out.append(e)
            }
        } else if c == "\"" {
            return concat(out)
        } else {
            out.append(c)
        }
        i = i + 1
    }
    return concat(out)
}






// ask sends one user message to Claude and returns the model's text reply (or the raw response if
// no text block was found — so an API error is visible rather than silently empty).
fn ask(api_key: string, model: string, user_msg: string) -> string {
    let body = build_request(model, 1024, user_msg)
    let headers = "content-type: application/json\nanthropic-version: 2023-06-01\nx-api-key: {api_key}"
    let resp = http.post("https://api.anthropic.com/v1/messages", headers, body)
    let text = extract_text(resp)
    if text.len() == 0 {
        return resp
    }
    return text
}






fn main() -> int {
    let key = env("ANTHROPIC_API_KEY")
    if key.len() == 0 {
        println("error: set ANTHROPIC_API_KEY in the environment")
        return 1
    }
    let a = args()
    var msg = "Say hello from the Ember programming language in one short sentence."
    if a.len() > 0 {
        msg = a[0]
    }
    println("> {msg}")
    println("")
    println(ask(key, "claude-opus-4-8", msg))
    return 0
}
