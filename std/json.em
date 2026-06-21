// std/json.em — a real JSON parser and serializer for Ember.
//
// It dogfoods the language: a JSON value is a recursive SUM TYPE (`enum Json`) walked with `match`,
// objects are a list of key/value `Member`s (insertion order preserved, which keeps serialization
// deterministic), and the parser is plain recursive descent over a `mut self` cursor. Numbers split
// into `Int`/`Real` so an Ember `int` round-trips as an integer (`max_tokens` stays `2048`) and a
// fraction stays a float (`temperature` stays `0.7`) instead of everything collapsing to `f64`.
//
//   import "std/json" as json
//   match json.parse(text) {
//       case Ok(v)    { let model = json.as_str(json.get(v, "model")) }
//       case Err(msg) { ... }
//   }
//   let body = json.stringify(Obj([json.member("model", Str("claude-opus-4-1"))]))

enum Json {
    Null
    Bool(b: bool)
    Int(i: int)
    Real(r: float)
    Str(s: string)
    Arr(items: [Json])
    Obj(members: [Member])
}

struct Member {
    key: string
    value: Json
}

// parse never throws: it returns the built-in Result<Json, string> — Ok(tree) on success,
// Err(message) on malformed input.






// _hex returns the value 0–15 of a hex digit, or -1 if `c` is not one.
fn _hex(c: string) -> int {
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
    return 0 - 1
}






// _is_digit reports whether `c` is an ASCII digit 0–9.
fn _is_digit(c: string) -> bool {
    let k = char_code(c)
    return k >= 48 && k <= 57
}






// _is_finite reports whether `r` is a finite float (not inf or nan): only a finite value satisfies
// `r - r == 0`. JSON has no token for infinity/NaN, so an over-range number must be rejected.
fn _is_finite(r: float) -> bool {
    return r - r == 0.0
}






// Parser is a recursive-descent cursor over the source's code points. Each `value`-level method
// consumes exactly one grammar production and advances `pos`; the first error is latched in `err`
// (subsequent calls become no-ops returning Null) so a malformed document fails cleanly, never hangs.
struct Parser {
    cs: [string]
    pos: int
    err: string
    depth: int          // current container nesting; capped so a pathological input fails cleanly

    fn peek(self) -> string {
        if self.pos >= self.cs.len() {
            return ""
        }
        return self.cs[self.pos]
    }


    fn at_end(self) -> bool {
        return self.pos >= self.cs.len()
    }


    fn advance(mut self) -> string {
        let c = self.peek()
        self.pos = self.pos + 1
        return c
    }


    fn fail(mut self, msg: string) {
        if self.err == "" {
            self.err = "{msg} at position {self.pos}"
        }
    }


    fn skip_ws(mut self) {
        loop {
            let c = self.peek()
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                let _ = self.advance()
            } else {
                break
            }
        }
    }


    // word consumes the literal `w` if it is next, else latches an error.
    fn word(mut self, w: string) -> bool {
        let want = w.chars()
        var i = 0
        loop {
            if i == want.len() {
                return true
            }
            if self.peek() != want[i] {
                self.fail("expected '{w}'")
                return false
            }
            let _ = self.advance()
            i = i + 1
        }
        return true
    }


    // value parses one JSON value (the grammar's entry production), dispatching on the next char.
    fn value(mut self) -> Json {
        self.skip_ws()
        if self.err != "" {
            return Null
        }
        let c = self.peek()
        if c == "" {
            self.fail("unexpected end of input")
            return Null
        }
        if c == "\"" {
            return Str(self.string_lit())
        }
        // Containers recurse (value → array/object → value …). The VM caps the call stack, so guard
        // nesting here and fail cleanly rather than abort: real JSON is shallow; 64 is generous and
        // stays well under the frame limit. depth is incremented around the recursive call and undone
        // after, so wide-but-shallow documents are unaffected.
        if c == "\{" {
            self.depth = self.depth + 1
            if self.depth > 64 {
                self.fail("maximum nesting depth (64) exceeded")
                self.depth = self.depth - 1
                return Null
            }
            let v = self.object()
            self.depth = self.depth - 1
            return v
        }
        if c == "[" {
            self.depth = self.depth + 1
            if self.depth > 64 {
                self.fail("maximum nesting depth (64) exceeded")
                self.depth = self.depth - 1
                return Null
            }
            let v = self.array()
            self.depth = self.depth - 1
            return v
        }
        if c == "t" {
            let _ = self.word("true")
            return Bool(true)
        }
        if c == "f" {
            let _ = self.word("false")
            return Bool(false)
        }
        if c == "n" {
            let _ = self.word("null")
            return Null
        }
        if c == "-" || self._is_digit(c) {
            return self.number()
        }
        self.fail("unexpected character '{c}'")
        let _ = self.advance()
        return Null
    }


    fn _is_digit(self, c: string) -> bool {
        let k = char_code(c)
        return k >= 48 && k <= 57
    }


    // string_lit parses a "..." string, decoding the JSON escape set (\" \\ \/ \b \f \n \r \t \uXXXX,
    // including a high+low surrogate pair into one astral code point). Assumes the opening quote is next.
    fn string_lit(mut self) -> string {
        var out: [string] = []
        let _ = self.advance()                  // opening quote
        loop {
            if self.at_end() {
                self.fail("unterminated string")
                break
            }
            let c = self.advance()
            if c == "\"" {
                break
            }
            if c == "\\" {
                let e = self.advance()
                if e == "\"" {
                    out.append("\"")
                } else if e == "\\" {
                    out.append("\\")
                } else if e == "/" {
                    out.append("/")
                } else if e == "n" {
                    out.append(from_char_code(10))
                } else if e == "t" {
                    out.append(from_char_code(9))
                } else if e == "r" {
                    out.append(from_char_code(13))
                } else if e == "b" {
                    out.append(from_char_code(8))
                } else if e == "f" {
                    out.append(from_char_code(12))
                } else if e == "u" {
                    out.append(from_char_code(self.unicode_escape()))
                } else {
                    self.fail("invalid string escape '\\{e}'")
                    break
                }
            } else if char_code(c) < 32 {
                self.fail("an unescaped control character is not allowed in a string")
                break
            } else {
                out.append(c)
            }
        }
        return concat(out)
    }


    // unicode_escape reads the 4 hex digits after a \u (the \u already consumed) and returns the code
    // point, combining a UTF-16 surrogate pair (\uD800–\uDBFF then \uDC00–\uDFFF) into one scalar.
    fn unicode_escape(mut self) -> int {
        let hi = self.hex4()
        if hi >= 55296 && hi <= 56319 {         // high surrogate — expect a following low surrogate
            if self.peek() == "\\" {
                let _ = self.advance()
                if self.peek() == "u" {
                    let _ = self.advance()
                    let lo = self.hex4()
                    if lo >= 56320 && lo <= 57343 {     // a valid low surrogate (\uDC00–\uDFFF)
                        return 65536 + (hi - 55296) * 1024 + (lo - 56320)
                    }
                    self.fail("invalid low surrogate after a high surrogate")
                    return 65533               // U+FFFD, so a fail path still yields a defined scalar
                }
            }
            self.fail("unpaired high surrogate")
            return 65533
        }
        if hi >= 56320 && hi <= 57343 {         // a lone low surrogate is not a valid scalar
            self.fail("unexpected low surrogate")
            return 65533
        }
        return hi
    }


    fn hex4(mut self) -> int {
        var v = 0
        var i = 0
        loop {
            if i == 4 {
                return v
            }
            let d = _hex(self.advance())
            if d < 0 {
                self.fail("invalid \\u hex digit")
                return v
            }
            v = v * 16 + d
            i = i + 1
        }
        return v
    }


    // number parses a JSON number, ENFORCING the grammar  -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    // rather than greedily swallowing a run — so leading zeros (01), a trailing dot (1.), an empty
    // exponent (1e), a lone minus, and a doubled exponent (1e2e3) are rejected, not silently coerced.
    // It then chooses Int (no fraction/exponent, fits i64) or Real, and refuses a non-finite Real (1e400).
    fn number(mut self) -> Json {
        var run: [string] = []
        var is_real = false
        if self.peek() == "-" {
            run.append(self.advance())
        }
        // integer part: a single 0, or [1-9] then more digits (no leading zeros)
        let first = self.peek()
        if first == "0" {
            run.append(self.advance())
            if self._is_digit(self.peek()) {
                self.fail("a number may not have a leading zero")
                return Null
            }
        } else if self._is_digit(first) {
            run.append(self.advance())
            loop {
                if !self._is_digit(self.peek()) {
                    break
                }
                run.append(self.advance())
            }
        } else {
            self.fail("expected a digit in number")
            return Null
        }
        // fraction: '.' then at least one digit
        if self.peek() == "." {
            is_real = true
            run.append(self.advance())
            if !self._is_digit(self.peek()) {
                self.fail("expected a digit after the decimal point")
                return Null
            }
            loop {
                if !self._is_digit(self.peek()) {
                    break
                }
                run.append(self.advance())
            }
        }
        // exponent: e/E, optional sign, then at least one digit
        let e = self.peek()
        if e == "e" || e == "E" {
            is_real = true
            run.append(self.advance())
            let sign = self.peek()
            if sign == "+" || sign == "-" {
                run.append(self.advance())
            }
            if !self._is_digit(self.peek()) {
                self.fail("expected a digit in the exponent")
                return Null
            }
            loop {
                if !self._is_digit(self.peek()) {
                    break
                }
                run.append(self.advance())
            }
        }
        let text = concat(run)
        if is_real {
            let r = parse_float(text)
            if !_is_finite(r) {
                self.fail("number out of range")
                return Null
            }
            return Real(r)
        }
        match text.parse_int() {
            case Some(v) { return Int(v) }
            case None {
                let r = parse_float(text)             // too many digits for i64 → fall back to Real
                if !_is_finite(r) {
                    self.fail("number out of range")
                    return Null
                }
                return Real(r)
            }
        }
        return Null
    }


    // array parses [ value, value, ... ]. Assumes '[' is next.
    fn array(mut self) -> Json {
        var items: [Json] = []
        let _ = self.advance()                  // '['
        self.skip_ws()
        if self.peek() == "]" {
            let _ = self.advance()
            return Arr(items)
        }
        loop {
            let v = self.value()
            if self.err != "" {
                break
            }
            items.append(v)
            self.skip_ws()
            let c = self.peek()
            if c == "," {
                let _ = self.advance()
                self.skip_ws()
            } else if c == "]" {
                let _ = self.advance()
                break
            } else {
                self.fail("expected ',' or ']' in array")
                break
            }
        }
        return Arr(items)
    }


    // object parses { "key": value, ... }. Assumes '{' is next.
    fn object(mut self) -> Json {
        var members: [Member] = []
        let _ = self.advance()                  // '{'
        self.skip_ws()
        if self.peek() == "\}" {
            let _ = self.advance()
            return Obj(members)
        }
        loop {
            self.skip_ws()
            if self.peek() != "\"" {
                self.fail("expected a string key in object")
                break
            }
            let key = self.string_lit()
            self.skip_ws()
            if self.peek() != ":" {
                self.fail("expected ':' after object key")
                break
            }
            let _ = self.advance()              // ':'
            let v = self.value()
            if self.err != "" {
                break
            }
            members.append(Member { key: key, value: v })
            self.skip_ws()
            let c = self.peek()
            if c == "," {
                let _ = self.advance()
            } else if c == "\}" {
                let _ = self.advance()
                break
            } else {
                self.fail("expected ',' or '}' in object")
                break
            }
        }
        return Obj(members)
    }
}






// parse turns JSON text into a Json tree, or an Err with a message + position on malformed input.
fn parse(text: string) -> Result<Json, string> {
    var p = Parser { cs: text.chars(), pos: 0, err: "", depth: 0 }
    let v = p.value()
    p.skip_ws()
    if p.err != "" {
        return Err(p.err)
    }
    if !p.at_end() {
        return Err("trailing characters after the JSON value at position {p.pos}")
    }
    return Ok(v)
}






// _escape renders `s` as the body of a JSON string literal (no surrounding quotes), escaping the
// characters JSON requires: quote, backslash, and the C0 control range (\n \t \r \b \f, else \u00XX).
fn _escape(s: string) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() {
            return concat(out)
        }
        let c = cs[i]
        let k = char_code(c)
        if c == "\"" {
            out.append("\\\"")
        } else if c == "\\" {
            out.append("\\\\")
        } else if k == 10 {
            out.append("\\n")
        } else if k == 9 {
            out.append("\\t")
        } else if k == 13 {
            out.append("\\r")
        } else if k == 8 {
            out.append("\\b")
        } else if k == 12 {
            out.append("\\f")
        } else if k < 32 {
            out.append("\\u00{_hex2(k)}")
        } else {
            out.append(c)
        }
        i = i + 1
    }
    return concat(out)
}






// _hex2 formats `k` (0–255) as exactly two lowercase hex digits.
fn _hex2(k: int) -> string {
    let lo = k % 16
    let hi = (k / 16) % 16
    return _hex_digit(hi) + _hex_digit(lo)
}






fn _hex_digit(n: int) -> string {
    if n < 10 {
        return from_char_code(48 + n)
    }
    return from_char_code(97 + (n - 10))
}






// stringify renders a Json tree as compact JSON text (no insignificant whitespace).
fn stringify(j: Json) -> string {
    return _stringify(j, 0)
}






// _stringify is the depth-tracked worker. Like the parser, it caps nesting (the public builders can
// construct a tree deeper than parse would ever return) so a pathological tree yields a bounded string
// instead of overflowing the call stack; a non-finite Real (only reachable via a builder) renders null,
// never the invalid token `inf`/`nan`.
fn _stringify(j: Json, depth: int) -> string {
    match j {
        case Null      { return "null" }
        case Bool(b)   { if b { return "true" } return "false" }
        case Int(i)    { return "{i}" }
        case Real(r)   { if !_is_finite(r) { return "null" } return "{r}" }
        case Str(s)    { return "\"{_escape(s)}\"" }
        case Arr(items) {
            if depth >= 64 {
                return "null"
            }
            var parts: [string] = []
            var i = 0
            loop {
                if i == items.len() {
                    break
                }
                parts.append(_stringify(items[i], depth + 1))
                i = i + 1
            }
            return "[{_join(parts)}]"
        }
        case Obj(members) {
            if depth >= 64 {
                return "null"
            }
            var parts: [string] = []
            var i = 0
            loop {
                if i == members.len() {
                    break
                }
                parts.append("\"{_escape(members[i].key)}\":{_stringify(members[i].value, depth + 1)}")
                i = i + 1
            }
            return "\{{_join(parts)}\}"
        }
    }
    return "null"
}






// _join concatenates parts with commas (the array/object element separator).
fn _join(parts: [string]) -> string {
    var out = ""
    var i = 0
    loop {
        if i == parts.len() {
            return out
        }
        if i > 0 {
            out = out + ","
        }
        out = out + parts[i]
        i = i + 1
    }
    return out
}






// member builds an object entry — `member("model", str("claude-opus-4-1"))`.
fn member(key: string, value: Json) -> Member {
    return Member { key: key, value: value }
}






// Builders. A `Json` value's variants can't be constructed from another module directly, so these
// public constructors are the building API — `obj([member("model", str("opus")), …])`. (They also
// keep call sites readable and let the representation change without touching callers.)
fn obj(members: [Member]) -> Json {
    return Obj(members)
}






fn arr(items: [Json]) -> Json {
    return Arr(items)
}






fn str(s: string) -> Json {
    return Str(s)
}






fn num(i: int) -> Json {
    return Int(i)
}






fn real(r: float) -> Json {
    return Real(r)
}






fn boolean(b: bool) -> Json {
    return Bool(b)
}






fn null_value() -> Json {
    return Null
}






// get returns the value for `key` in an object (Null if absent or `j` is not an object).
fn get(j: Json, key: string) -> Json {
    match j {
        case Obj(members) {
            var i = 0
            loop {
                if i == members.len() {
                    break
                }
                if members[i].key == key {
                    return members[i].value
                }
                i = i + 1
            }
        }
        case Null {}
        case Bool(b) {}
        case Int(i) {}
        case Real(r) {}
        case Str(s) {}
        case Arr(items) {}
    }
    return Null
}






// at returns element `idx` of an array (Null if out of range or `j` is not an array).
fn at(j: Json, idx: int) -> Json {
    match j {
        case Arr(items) {
            if idx >= 0 && idx < items.len() {
                return items[idx]
            }
        }
        case Null {}
        case Bool(b) {}
        case Int(i) {}
        case Real(r) {}
        case Str(s) {}
        case Obj(members) {}
    }
    return Null
}






// length is the element count of an array or object (0 for anything else).
fn length(j: Json) -> int {
    match j {
        case Arr(items)   { return items.len() }
        case Obj(members) { return members.len() }
        case Null {}
        case Bool(b) {}
        case Int(i) {}
        case Real(r) {}
        case Str(s) {}
    }
    return 0
}






// as_str extracts a string value ("" for any non-string).
fn as_str(j: Json) -> string {
    match j {
        case Str(s) { return s }
        case Null {}
        case Bool(b) {}
        case Int(i) {}
        case Real(r) {}
        case Arr(items) {}
        case Obj(members) {}
    }
    return ""
}






// as_int extracts an integer (truncating a Real; 0 for non-numbers).
fn as_int(j: Json) -> int {
    match j {
        case Int(i)  { return i }
        case Real(r) { return to_int(r) }
        case Null {}
        case Bool(b) {}
        case Str(s) {}
        case Arr(items) {}
        case Obj(members) {}
    }
    return 0
}






// as_real extracts a float (promoting an Int; 0.0 for non-numbers).
fn as_real(j: Json) -> float {
    match j {
        case Real(r) { return r }
        case Int(i)  { return to_float(i) }
        case Null {}
        case Bool(b) {}
        case Str(s) {}
        case Arr(items) {}
        case Obj(members) {}
    }
    return 0.0
}






// as_bool extracts a boolean (false for any non-boolean).
fn as_bool(j: Json) -> bool {
    match j {
        case Bool(b) { return b }
        case Null {}
        case Int(i) {}
        case Real(r) {}
        case Str(s) {}
        case Arr(items) {}
        case Obj(members) {}
    }
    return false
}






// is_null reports whether `j` is the null value.
fn is_null(j: Json) -> bool {
    match j {
        case Null { return true }
        case Bool(b) {}
        case Int(i) {}
        case Real(r) {}
        case Str(s) {}
        case Arr(items) {}
        case Obj(members) {}
    }
    return false
}
