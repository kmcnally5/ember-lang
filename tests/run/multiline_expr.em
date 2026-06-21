// multiline_expr.em — an expression continues across newlines while inside
// unclosed ( or [ (a grouped expression, a call's arguments, an array literal),
// and also when a line ends with a binary operator. Outside brackets a newline
// still terminates a statement.
fn add4(a: int, b: int, c: int, d: int) -> int {
    return a + b + c + d
}

fn main() -> int {
    let grouped = (1 + 2 + 3 +
                   4 + 5 +
                   6)                  // 21
    let args = add4(10,
                    20,
                    30,
                    40)                // 100
    let arr = [1, 2,
               3, 4,
               5]                      // arr[4] = 5
    return grouped + args + arr[4]     // 21 + 100 + 5 = 126
}
