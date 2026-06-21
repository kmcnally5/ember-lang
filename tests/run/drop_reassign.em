// drop_reassign.em — reassigning a `var` (or a struct field) that owns a value
// releases the value it held before, rather than leaking it. The new value is
// computed first, so `acc = acc + "a"` still reads the old `acc`; then the old one
// is freed and the slot/field takes the new value. Correct output proves no use-
// after-free (the old value lives through the right-hand side) and no double free.
struct Box { s: string }

fn main() -> string {
    var acc = ""
    for x in [1, 2, 3] {
        acc = acc + "a"          // old acc released after the concat reads it
    }
    var b = Box { s: "old" }
    b.s = "new"                  // old field value "old" released
    return acc + b.s             // "aaa" + "new" => aaanew
}
