// tests/run/array_remove_at.em — regression for the `remove_at(i)` array intrinsic (the index-place pop
// that OFI-072's cost/benefit flagged as the genuinely-missing primitive — per-chat delete wants it).
// Covers int, string (refcounted leaf), and value-struct elements; verifies the removed element is the
// right one, the tail shifts down, the length shrinks, and nothing double-frees (the harness also runs
// the native backend, and Crucible fuzzes the value-struct path across heap-leaf shapes).
struct Conv { title: string  n: int }


fn main() -> int {
    var xs: [int] = [10, 20, 30, 40]
    let r = xs.remove_at(1)                                          // remove 20
    print("r={r} xs=[{xs[0]},{xs[1]},{xs[2]}] len={xs.len()}\n")     // r=20 xs=[10,30,40] len=3

    var ss: [string] = ["a", "b", "c"]
    let s = ss.remove_at(0)                                          // remove a refcounted element
    print("s={s} ss0={ss[0]} len={ss.len()}\n")                      // s=a ss0=b len=2

    var cv: [Conv] = []
    cv.append(Conv { title: "x", n: 1 })
    cv.append(Conv { title: "y", n: 2 })
    cv.append(Conv { title: "z", n: 3 })
    let c = cv.remove_at(1)                                          // remove the value-struct {y,2}
    print("c={c.title}/{c.n} keep=[{cv[0].title},{cv[1].title}] len={cv.len()}\n")  // y/2 [x,z] 2

    let last = xs.remove_at(xs.len() - 1)                            // remove_at the last index = pop
    print("last={last} len={xs.len()}\n")                            // last=40 len=2
    return 0
}
