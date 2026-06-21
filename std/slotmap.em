// std/slotmap.em — a generic generational-arena SlotMap<V>, written in Ember. The store owns the
// values; callers hold small copyable `Handle`s (a slot index + a generation) instead of pointers,
// so IDENTITY (the handle) is separated from OWNERSHIP (the store). Removing a value bumps its
// slot's generation, so every outstanding handle to it becomes STALE and reads back as `None`
// rather than a dangling value — the C/raw-index footgun (a silent wrong-entity read after a slot
// is recycled, the classic ABA bug) is turned into a safe `Option` by construction.
//
// A freed slot is recycled by `insert` (a free-list keeps reuse O(1)); the backing arrays never
// shrink, so live handles keep stable indices. A move-type value (struct/array) is stored by
// structural deep-clone (the runtime's own_into_slot, the same clone that makes aggregates sound
// through generics), so the arena owns its copy with no `clone()` ceremony; a shareable value
// (scalar/string/enum) is stored directly. Reading a value out (`get`/`values`) is non-destructive
// — it returns a copy, the arena keeps its own.
//
//   Import it:  import "std/slotmap" as sm
//               var arena = sm.SlotMap<Particle>{ items: [], gen: [], free: [], count: 0 }
//
// There is no in-place `get_mut`: Ember has no interior mutability, so to change a stored value you
// read it out, edit your copy, and write it back with `replace` (the handle stays valid).
//
// Generations: `gen` is a 64-bit int bumped once per remove of a given slot, so wraparound is
// ~9.2e18 removes away — irrelevant for any real run. A multi-decade process wanting a hard
// guarantee could retire a slot permanently (never push it back to `free`) once its generation peaks.

// Handle names a value in a SlotMap: `idx` is the slot, `gen` the generation the value was inserted
// at. It is a plain value (two ints) — cheap to copy, store, and pass around — and owns nothing. A
// handle whose `gen` no longer matches its slot's live generation is STALE (its value was removed,
// possibly with the slot since recycled for a different value), and every lookup treats it as absent.
struct Handle {
    idx: int
    gen: int
}





struct SlotMap<V> {
    items: [Option<V>]   // per-slot payload; `None` marks a free slot
    gen:   [int]         // per-slot live generation, bumped on every remove
    free:  [int]         // stack of free slot indices, popped first by `insert` to recycle
    count: int           // number of live values


    // size returns the number of live values held.
    fn size(self) -> int {
        return self.count
    }


    // is_empty reports whether the arena holds no live values.
    fn is_empty(self) -> bool {
        return self.count == 0
    }


    // insert stores v and returns a fresh Handle to it. A previously freed slot is recycled if one
    // is available (popped from the free-list), otherwise the backing arrays grow by one. The
    // returned handle carries the slot's current generation, so it stays valid until v is removed.
    fn insert(mut self, v: V) -> Handle {
        var i = -1
        if self.free.len() > 0 {
            i = self.free.remove_last()
            self.items[i] = Some(v)
        } else {
            i = self.items.len()
            self.items.append(Some(v))
            self.gen.append(0)
        }
        self.count = self.count + 1
        return Handle { idx: i, gen: self.gen[i] }
    }


    // get returns Some(value) for a live handle, or None if the handle is out of range or STALE.
    // Whenever the generation matches, the slot is guaranteed occupied (a remove always bumps the
    // generation), so returning the slot's Option directly yields the live Some(value).
    fn get(self, h: Handle) -> Option<V> {
        if h.idx < 0 { return None }
        if h.idx >= self.items.len() { return None }
        if self.gen[h.idx] != h.gen { return None }
        return self.items[h.idx]
    }


    // contains reports whether h still names a live value. (Generation match implies the slot is
    // occupied, so no payload check is needed — see `get`.)
    fn contains(self, h: Handle) -> bool {
        if h.idx < 0 { return false }
        if h.idx >= self.items.len() { return false }
        return self.gen[h.idx] == h.gen
    }


    // replace overwrites the value behind a LIVE handle, dropping the old value and keeping the
    // handle valid (the generation is unchanged). Returns false — changing nothing — if the handle
    // is out of range or stale. This is how you "mutate" a stored value: read it out, edit your
    // copy, write it back. The assignment drops the previous Some(value) exactly once.
    fn replace(mut self, h: Handle, v: V) -> bool {
        if h.idx < 0 { return false }
        if h.idx >= self.items.len() { return false }
        if self.gen[h.idx] != h.gen { return false }
        self.items[h.idx] = Some(v)
        return true
    }


    // remove deletes the value behind h, returning true if it was live. The slot's generation is
    // bumped (invalidating every outstanding handle to it) and the slot is pushed onto the free-list
    // for reuse; setting the slot to None drops the removed value exactly once. Removing an
    // out-of-range or stale handle is a no-op returning false (so a double-remove is safe).
    fn remove(mut self, h: Handle) -> bool {
        if h.idx < 0 { return false }
        if h.idx >= self.items.len() { return false }
        if self.gen[h.idx] != h.gen { return false }
        self.items[h.idx] = None
        self.gen[h.idx] = self.gen[h.idx] + 1
        self.free.append(h.idx)
        self.count = self.count - 1
        return true
    }


    // values returns every live value (in slot order, not insertion order). Non-destructive: each
    // value is copied out, the arena keeps its own.
    fn values(self) -> [V] {
        var vs: [V] = []
        var i = 0
        loop {
            if i == self.items.len() { return vs }
            match self.items[i] {
                case Some(v) { vs.append(v) }
                case None { }
            }
            i = i + 1
        }
        return vs
    }


    // handles returns a live Handle for every stored value (in slot order), pairing each occupied
    // slot with its current generation. Useful for iterating, then mutating via `replace`/`remove`.
    fn handles(self) -> [Handle] {
        var hs: [Handle] = []
        var i = 0
        loop {
            if i == self.items.len() { return hs }
            match self.items[i] {
                case Some(v) { hs.append(Handle { idx: i, gen: self.gen[i] }) }
                case None { }
            }
            i = i + 1
        }
        return hs
    }
}
