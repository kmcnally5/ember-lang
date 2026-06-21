// error_field_missing.em — every field must be set exactly once at construction.
struct P { x: int  y: int }
fn main() -> int { let p = P { x: 3 }  return p.x }
