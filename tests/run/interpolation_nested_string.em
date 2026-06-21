// interpolation_nested_string.em — OFI-011: an interpolation hole may contain a
// string literal, even one with braces. The lexer (scanning the outer literal)
// and the hole-splitter both track nested strings, so an inner `"` does not end
// the outer string and an inner `}` does not end the hole prematurely.
fn main() -> int {
    let csv = "a,bb,ccc"
    println("split count = {csv.split(",").len()}")   // split count = 3
    println("concat = {"x" + "y" + "z"}")             // concat = xyz
    println("brace in string len = {"a}b".len()}")    // brace in string len = 3
    return 0
}
