// error_mut_let_arg.em — locks the mutable-borrow rule (REVIEW_FINDINGS H5): an
// argument bound to a `mut` parameter must be a mutable place, never an immutable
// `let`. Without this check, `fill(mut a)` would write through the borrow into the
// frozen `let` array (`a[0]` would become 99), silently violating let-immutability.
fn fill(mut a: [int]) {
    a[0] = 99
}


fn main() -> int {
    let a = [1, 2, 3]
    fill(a)
    return a[0]
}
