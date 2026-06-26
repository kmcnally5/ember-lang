// error_resource_clone_match.em — OFI-122 R2: a `resource` is uniquely owned, so it may not be moved
// or copied OUT of a borrow. Binding it out of a `match` case (which borrows the matched payload) would
// shallow-copy its handle, giving two owners that each run `drop` — a double-close. Compile error.
resource struct R {
    id: int
    fn drop(self) { println("drop {self.id}") }
}
fn f(res: Result<R, string>) -> int {
    match res {
        case Ok(r) {
            let keep = r
            return 0
        }
        case Err(e) { return 1 }
    }
}
fn main() -> int { return 0 }
