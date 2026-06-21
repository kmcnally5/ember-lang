// error_sized_mix.em — integer widths do not implicitly coerce; mixing an i32 and
// an i64 is a compile error (convert one explicitly with a type-name call).
fn main() -> int {
    let a: i32 = 5
    let b: i64 = 9
    let c = a + b
    return c
}
