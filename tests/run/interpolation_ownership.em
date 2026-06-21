// tests/run/interpolation_ownership.em — OFI-059: interpolation no longer leaks its intermediate
// concat temporaries. The fold uses a CONSUMING OP_CONCAT and OP_TO_STRING returns an OWNED
// string, so every operand is owned and the intermediates are freed. This locks the OBSERVABLE
// behaviour: a borrowed-string hole leaves its source intact, single- and multi-hole results are
// correct, and repeated interpolation in a loop is stable. (The leak itself is RSS-verified, as
// leaks are throughout this project — LSan is unsupported here.)

fn main() -> int {
    // A borrowed string var as a hole — the source must survive being interpolated.
    let name = "Ada"
    let greet = "Hello, {name}!"
    print(greet)
    print(" / source still: ")
    print(name)
    print("\n")

    // Single-hole (pure passthrough) — owns its own result, source intact.
    let echo = "{name}"
    print(echo)
    print(" ")
    print(name)
    print("\n")

    // Multi-hole, mixed types.
    let n = 3
    print("n={n} name={name} again={name}")
    print("\n")

    // Repeated interpolation in a loop — sum the lengths to prove stable behaviour.
    var i = 0
    var total = 0
    loop {
        if i == 5 { break }
        let row = "item {i} / {name}"
        total = total + row.len()
        i = i + 1
    }
    print("total=")
    print("{total}")
    return 0
}
