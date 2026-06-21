// clone.em — `.clone()` deep copy on ARRAYS, differential (VM == native binary). Value-struct
// .clone() is VM-only for now (OFI-082 native follow-up), so this covers only the array cases,
// which the native backend supports fully (arrays are boxed Values — no em_s representation gap).
fn main() -> int {
    // deep array copy: the clone grows independently of the source
    var nums: [int] = [1, 2, 3]
    var copy = nums.clone()
    copy.append(4)
    copy.append(5)
    println("nums={nums.len()} copy={copy.len()}")          // 3 / 5

    // clone an array reached through an index (array of arrays)
    var grid: [[int]] = []
    grid.append([9, 9, 9])
    var row = grid[0].clone()
    row.append(0)
    println("grid0={grid[0].len()} row={row.len()}")        // 3 / 4

    // clone a borrowed array twice; the two copies are independent
    var base: [int] = [7]
    var a = base.clone()
    var b = base.clone()
    a.append(1)
    b.append(2)
    b.append(3)
    println("base={base.len()} a={a.len()} b={b.len()}")    // 1 / 2 / 3
    return 0
}
