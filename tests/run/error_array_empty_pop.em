// error_array_empty_pop.em — remove_last on an empty array is a runtime error
// (there is no element to hand back), like an out-of-bounds index.
fn main() -> int {
    var xs: [int] = []
    return xs.remove_last()
}
