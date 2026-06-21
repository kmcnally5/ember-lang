// array_index_mutate.em — regression for OFI-072: `append` through an index now PERSISTS.
// A mutating method whose receiver is reached through an index or a value-struct field used to
// mutate a clone and silently lose the write (arr[i].xs.append(x) was a no-op). Codegen now lowers
// it as read-modify-write (append into the clone, then assign the whole array back), in BOTH the VM
// and the native backend. This locks all three shapes plus the case that must stay an in-place
// mutation (a plain local), and a whole-field overwrite between appends (the release-old path).
struct Msg {
    role: string
    text: string
}


struct Conv {
    title: string
    lines: [Msg]
    tags: [string]
}


fn main() -> int {
    // (1) [[T]]: append through an index into the inner array
    var grid: [[string]] = []
    grid.append([])
    grid.append([])
    grid[0].append("a")
    grid[0].append("b")
    grid[1].append("c")
    println("grid: {grid[0].len()} {grid[1].len()}")          // 2 1

    // (2) struct-in-array array fields: append through the index, both a struct field and a string field
    var cs: [Conv] = []
    cs.append(Conv { title: "first", lines: [], tags: [] })
    cs.append(Conv { title: "second", lines: [], tags: [] })
    cs[0].lines.append(Msg { role: "user", text: "hi" })
    cs[0].lines.append(Msg { role: "claude", text: "hello" })
    cs[0].tags.append("greeting")
    cs[1].lines.append(Msg { role: "user", text: "bye" })
    println("c0: {cs[0].lines.len()} lines {cs[0].tags.len()} tags; c1: {cs[1].lines.len()}")  // 2 1 1

    // (3) whole-field overwrite (release-old) then keep appending through the index
    cs[0].tags = ["x"]
    cs[0].tags.append("y")
    println("c0 tags after reset: {cs[0].tags.len()} [{cs[0].tags[0]},{cs[0].tags[1]}]")  // 2 [x,y]

    // (4) the must-stay-in-place case: a plain local field
    var solo = Conv { title: "solo", lines: [], tags: [] }
    solo.lines.append(Msg { role: "user", text: "local" })
    println("local: {solo.lines.len()}")                       // 1

    // read a value back to prove element contents survived the write-backs
    println("sample: {cs[0].lines[1].text} {grid[1][0]}")      // hello c
    return 0
}
