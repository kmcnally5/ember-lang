// clone.em — `.clone()` deep copy for value-structs and arrays (OFI-082). A clone is an
// INDEPENDENT copy: mutating it never affects the original, and vice versa. The receiver is
// READ, not consumed, so `arr[i].clone()` is legal where the bare move-out `dst.append(arr[i])`
// is rejected. VM backend (the canonical one; native covers the array cases — see tests/native).
import "std/map" as mp


struct Conv {
    title: string
    msgs: [string]
}


fn main() -> int {
    // 1. The headline case: copy a value-struct OUT of an array element.
    var convos: [Conv] = []
    convos.append(Conv { title: "a", msgs: ["hi"] })
    convos.append(Conv { title: "b", msgs: ["yo", "sup"] })

    var backup: [Conv] = []
    backup.append(convos[0].clone())
    backup.append(convos[1].clone())

    convos[0].title = "MUT"                       // mutate the original
    println("orig0={convos[0].title} clone0={backup[0].title}")    // MUT / a
    println("clone1.msgs={backup[1].msgs.len()}")                  // 2

    // 2. Clone a plain local value-struct (borrow receiver).
    let c = Conv { title: "x", msgs: ["one"] }
    let d = c.clone()
    println("c={c.title} d={d.title}")                             // x / x

    // 3. Deep-clone an array — the copy grows independently.
    var nums: [int] = [1, 2, 3]
    var copy = nums.clone()
    copy.append(4)
    println("nums={nums.len()} copy={copy.len()}")                 // 3 / 4

    // 4. Clone a nested array element (array of arrays).
    var grid: [[int]] = []
    grid.append([9, 9])
    var row = grid[0].clone()
    row.append(0)
    println("grid0={grid[0].len()} row={row.len()}")               // 2 / 3

    // 5. Clone an array reached through a field-of-index (`cs[i].field`).
    var both = convos[1].msgs.clone()
    both.append("z")
    println("field_orig={convos[1].msgs.len()} field_clone={both.len()}")   // 2 / 3

    // 6. Deep-clone a generic struct (Map<K,V>) — the copy is fully independent.
    var m = mp.Map<int, int> { buckets: [], count: 0 }
    m.set(1, 10)
    m.set(2, 20)
    var n = m.clone()
    n.set(3, 30)
    println("m={m.size()} n={n.size()} m_has3={m.has(3)} n_has3={n.has(3)}")  // 2 / 3 / false / true
    return 0
}
