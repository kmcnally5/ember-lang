// tests/graphics/flare_forget.em — regression for std/flare's f.forget (state disposal / unmount).
// f.forget(key) prunes every keyed-state entry stored under `key`'s scope (`key + "/"…`, exactly what
// state_int/str/bool/float write after f.key(key)) from all four state columns, so a removed component's
// state does not leak. Pure state logic — no window or rendering. Locks in: full subtree removal across
// all four columns; untouched siblings; and the "/" boundary — forget("panel-a") must NOT prune the
// similarly-named "panel-ab" (the prefix test is scope-delimited, not a bare string prefix).
import "std/flare" as flare

fn main() -> int {
    var f = flare.new()

    f.key("panel-a")
    f.set_int("count", 5)
    f.set_str("title", "Alpha")
    f.set_bool("open", true)
    f.set_float("scroll", 1.5)

    f.key("panel-ab")          // shares the "panel-a" text but is a distinct scope
    f.set_int("count", 42)

    f.key("panel-b")
    f.set_int("count", 9)
    f.set_str("title", "Bravo")

    f.forget("panel-a")        // dispose ONLY panel-a's subtree

    f.key("panel-a")
    let a_c = f.state_int("count", -1)
    let a_t = f.state_str("title", "GONE")
    let a_o = f.state_bool("open", false)
    let a_s = f.state_float("scroll", -1.0)
    println("panel-a: count={a_c} title={a_t} open={a_o} scroll={a_s}")

    f.key("panel-ab")
    let ab_c = f.state_int("count", -1)
    println("panel-ab: count={ab_c}")

    f.key("panel-b")
    let b_c = f.state_int("count", -1)
    let b_t = f.state_str("title", "GONE")
    println("panel-b: count={b_c} title={b_t}")

    return 0
}
