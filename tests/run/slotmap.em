// slotmap.em — regression for std/slotmap: generational handles, the stale-handle -> None safety
// property, slot reuse with a fresh generation, in-place replace, double-remove-is-safe, and
// iteration. V is a value-struct (Particle) so the store-by-deep-clone path is exercised too.
import "std/slotmap" as sm

struct Particle {
    x: int
    y: int
}

fn main() -> int {
    var arena: sm.SlotMap<Particle> = sm.SlotMap<Particle>{ items: [], gen: [], free: [], count: 0 }

    let h1 = arena.insert(Particle { x: 1, y: 2 })
    let h2 = arena.insert(Particle { x: 3, y: 4 })
    print("size={arena.size()} empty={arena.is_empty()}\n")

    match arena.get(h1) {
        case Some(p) { print("h1=({p.x},{p.y})\n") }
        case None { print("h1 missing\n") }
    }

    let r = arena.replace(h1, Particle { x: 10, y: 20 })
    print("replace={r}\n")
    match arena.get(h1) {
        case Some(p) { print("h1'=({p.x},{p.y})\n") }
        case None { print("h1 missing\n") }
    }

    let ok = arena.remove(h1)
    let has1 = arena.contains(h1)
    print("remove={ok} contains_h1={has1} size={arena.size()}\n")
    match arena.get(h1) {
        case Some(p) { print("BUG stale read ({p.x})\n") }
        case None { print("h1 stale -> None\n") }
    }

    let again = arena.remove(h1)
    print("remove_again={again}\n")

    let h3 = arena.insert(Particle { x: 9, y: 9 })
    print("h3.idx={h3.idx} h3.gen={h3.gen} h1.gen={h1.gen}\n")
    match arena.get(h1) {
        case Some(p) { print("BUG old handle reads after reuse\n") }
        case None { print("old h1 still None after reuse\n") }
    }
    match arena.get(h3) {
        case Some(p) { print("h3=({p.x},{p.y})\n") }
        case None { print("h3 missing\n") }
    }
    match arena.get(h2) {
        case Some(p) { print("h2=({p.x},{p.y})\n") }
        case None { print("h2 missing\n") }
    }

    let vs = arena.values()
    print("values:")
    var i = 0
    loop {
        if i == vs.len() { break }
        print(" ({vs[i].x},{vs[i].y})")
        i = i + 1
    }
    print("\n")

    let hs = arena.handles()
    print("handles={hs.len()} size={arena.size()}\n")
    return 0
}
