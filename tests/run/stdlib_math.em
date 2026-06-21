// stdlib_math.em — math + char native primitives (sqrt/pow/abs/floor/ceil/round,
// char_code/from_char_code, parse_float). random() is non-deterministic, so not here.
fn main() -> int {
    println("sqrt(16)={sqrt(16.0)} pow(2,3)={pow(2.0, 3.0)} abs={abs(0.0 - 7.0)}")
    println("floor(2.9)={floor(2.9)} ceil(2.1)={ceil(2.1)} round(2.5)={round(2.5)}")
    let code = char_code("Z")                   // 90
    let ch = from_char_code(code)               // "Z"
    println("code={code} ch={ch} pf={parse_float("2.5") * 2.0}")
    return to_int(sqrt(16.0)) + code            // 4 + 90 = 94
}
