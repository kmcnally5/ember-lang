// variant_qualified_construct.em — OFI-073 Stage 2: construct an IMPORTED module's enum variants
// directly with `module.Variant(args)`, no builder boilerplate. The checker resolves the variant in
// the aliased module and stamps the enum id + tag; codegen builds it from those. Runs as a tests/
// native dual-run too, so the compiled binary must agree with the VM.
import "std/json" as json

fn main() -> int {
    let t = json.Obj([
        json.member("s", json.Str("hi")),
        json.member("n", json.Int(7)),
        json.member("r", json.Real(1.5)),
        json.member("b", json.Bool(true)),
        json.member("xs", json.Arr([json.Int(1), json.Int(2), json.Int(3)]))
    ])
    println(json.stringify(t))
    // round-trip the qualified-constructed tree back through parse + accessors
    let n = json.as_int(json.get(t, "n"))
    let s = json.as_str(json.get(t, "s"))
    let len = json.length(json.get(t, "xs"))
    println("n={n} s={s} xs_len={len}")
    return 0
}
