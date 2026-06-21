// arithmetic.em — locks the executed result of a mixed-operator integer
// expression: (10 - 4) / 2  +  7 % 3 * -1  =  3 + (-1)  =  2
fn main() -> int {
    return (10 - 4) / 2 + 7 % 3 * -1
}
