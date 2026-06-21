// interp_bool.em — a bool interpolates as true/false (2026-06-19; was previously rejected, but
// printing a bool is a reasonable, common need — the render is unambiguous unlike a bare 0/1).
fn main() -> int {
    let yes = true
    let no = false
    println("yes={yes} no={no} expr={3 > 1} and={yes && no}")
    return 0
}
