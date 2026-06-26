// error_move_self_after_move.em — a `move self` method consumes its receiver, so using the binding
// after the call is a use-after-move compile error (OFI-145 / R5p2: the prerequisite that makes
// `resource struct` drop-once sound — a move-self that leaves the receiver live would double-drop).
struct Wrap {
    s: string
    fn take(move self) -> int { return self.s.len() }
}
fn main() -> int {
    let w = Wrap { s: "hi" }
    let a = w.take()
    let b = w.take()
    return a + b
}
