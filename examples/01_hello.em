// 01_hello.em — the basics. Carries FROG's `let`/`fn`, adds static types.
//
// LLM-friendliness notes (the whole point of this design):
//   - Every statement is keyword-led (let/var/fn/return) — unambiguous to parse AND generate.
//   - Types are visible at every boundary, so the model never has to guess a contract.
//   - `let` = immutable, `var` = mutable. Two distinct words, no `let mut` two-token form.

fn main() {
    let name = "Ember"          // type inferred as `string` — inference is fine for locals
    let year: int = 2026        // explicit annotation when you want it

    var count = 0               // `var` => mutable
    count = count + 1

    println("Hello from {name}, {year}.")   // string interpolation with {braces}
}

// A plain function. `->` gives the return type. FROG had optional types here; Ember requires
// them on function signatures (the contract is where types matter most — for humans and LLMs).
fn add(a: int, b: int) -> int {
    return a + b
}
