// qualified_variant.em — OFI-013 regression. A variant may be constructed through
// its enum name: `Option.Some(7)`, `Option.None`, `Result.Ok(x)`, `Color.Blue(5)`.
// The checker desugars `Enum.Variant` to the bare variant (variant names are globally
// unique), so it lowers exactly like `Some(7)`. Bare and qualified forms interoperate.
enum Color { Red  Green  Blue(shade: int) }

fn pick(n: int) -> Result<int, string> {
    if n > 0 { return Result.Ok(n) }
    return Result.Err("non-positive")
}

fn main() -> int {
    let a = Option.Some(7)               // qualified, data-carrying
    let b: Option<int> = Option.None     // qualified, zero-field (needs annotation)
    let c = Color.Blue(5)                // qualified user enum
    let d = Color.Red                    // qualified zero-field user enum
    var s = 0
    match a { case Some(n) { s = s + n } case None { } }                  // +7
    match b { case Some(n) { s = s + n } case None { s = s + 100 } }      // +100
    match c { case Red { } case Green { } case Blue(x) { s = s + x } }    // +5
    match d { case Red { s = s + 1 } case Green { } case Blue(x) { } }    // +1
    match pick(3) { case Ok(v) { s = s + v } case Err(e) { } }            // +3
    match pick(0) { case Ok(v) { } case Err(e) { s = s + e.len() } }      // +12 ("non-positive")
    return s                                                              // 128
}
