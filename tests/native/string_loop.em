// Native backend (M2) differential test: strings under iteration.
// Concatenation + interpolation temporaries in a loop, an aliased binding (retain/release),
// and .len() accumulation — guards refcount balance and the exit-sweep reclaim of temps.
fn label(n: int) -> string {
    return "item-" + "{n}"
}

fn main() -> int {
    let base = "row"
    let alias = base
    var total = 0
    for i in 0..1000 {
        let s = label(i) + ":" + base
        total = total + s.len()
    }
    return total + alias.len() + base.len()
}
