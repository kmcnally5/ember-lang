// M5m fixture for the self-hosted C-emit backend: enum-PAYLOAD ownership (a parser hot path — the AST is
// enums and match extracts + reuses payloads). A `case V(s)` binding of a REFCOUNTED (string / enum /
// struct) payload field is a BORROW (em_enum_field — the enum owns it), but CONSUMING it in a `+` (string
// concat) owns it INTO the concat via own_into_slot (a retain into the consume; moves_local==2), NOT the
// generic borrow retain-dance a scalar payload / a `==` operand gets. The payload field types come from a
// per-variant payload-field table (pf_refc). Byte-identical to stage-0 `emberc --emit=c` (gated).
enum Tok {
    End
    Num(v: int)
    Name(s: string)
    Op(sym: string)
}


fn render(t: Tok) -> string {
    match t {
        case Name(s) {
            return s + "!"
        }
        case Op(sym) {
            return "[" + sym + "]"
        }
        case Num(v) {
            return "n"
        }
        case End {
            return "eof"
        }
    }
    return "?"
}


fn main() -> int {
    let a = render(Name("id"))
    let b = render(Op("+"))
    let c = render(Num(3))
    return a.len() + b.len() + c.len()
}
