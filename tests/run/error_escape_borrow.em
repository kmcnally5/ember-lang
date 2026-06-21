// error_escape_borrow.em — returning a borrowed parameter would let a reference escape the
// function; ownership must be taken with `move`. Uses a unique-owner struct (a boxed `string`
// field makes it a move type, not a copy) so the rule still applies — an ALL-SCALAR struct is a
// copy type and may be returned by value (see struct_return_copy_param.em / OFI-028).
struct Named { id: int  label: string }
fn identity(p: Named) -> Named {
    return p
}
fn main() -> int { return 0 }
