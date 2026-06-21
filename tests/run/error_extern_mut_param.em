// error_extern_mut_param.em — an extern (C) function passes arguments by value, so `mut`/`move`
// are meaningless and would also break the leaf-flattening the C boundary needs (the arg would be
// passed boxed). The checker rejects a qualified extern parameter (FFI, found in code review).
struct Vec2 { x: f64  y: f64 }
extern "c" {
    fn cvec2_len(mut v: Vec2) -> f64
}
fn main() -> int { return 0 }
