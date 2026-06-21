// std/set.em — a generic hash set Set<K: Hash + Eq>, written in Ember. It mirrors
// std/map's open-addressing table (linear probing, a None slot is empty, doubling past a 0.7
// load factor) but stores only keys — there is no value. Membership, insertion, and iteration
// are amortised O(1) / O(n). Adding a key already present is a no-op (a set holds each at most once).
//
//   Import it:  import "std/set" as st  ->  st.Set<string>{ slots: [], count: 0 }
//
// K must be Hash + Eq (to bucket and compare). A built-in key (scalar/string/enum) copies cheaply;
// a move-type struct key is deep-cloned structurally on store (sound, no double-free — OFI-042).
struct Set<K: Hash + Eq> {
    slots: [Option<K>]
    count: int


    // size returns the number of distinct keys held.
    fn size(self) -> int {
        return self.count
    }


    // _index maps a key to its starting slot. The sign bit is cleared (matching the native
    // hasher, vm.c NATIVE_HASH_ANY) so a user `Hash` impl that returns a NEGATIVE int can
    // never produce a negative `% cap` index — which would trap with "array index out of
    // bounds". Computed once per operation; the probe walks on with `(i + 1) % cap`.
    fn _index(self, key: K, cap: int) -> int {
        return (key.hash() & 9223372036854775807) % cap
    }


    // has reports whether key is in the set. Probing stops at the first empty slot,
    // which always exists because the load factor is kept below 1.
    fn has(self, key: K) -> bool {
        if self.slots.len() == 0 { return false }
        let cap = self.slots.len()
        var i = self._index(key, cap)
        loop {
            match self.slots[i] {
                case Some(k) { if k.eq(key) { return true } }
                case None { return false }
            }
            i = (i + 1) % cap
        }
        return false
    }


    // add inserts key, growing the table first if needed. A key already present is a no-op.
    fn add(mut self, key: K) {
        self._ensure_capacity()
        self._put(key)
    }


    // items returns every stored key (in bucket order, not insertion order).
    fn items(self) -> [K] {
        var ks: [K] = []
        var i = 0
        loop {
            if i == self.slots.len() { return ks }
            match self.slots[i] {
                case Some(k) { ks.append(k) }
                case None { }
            }
            i = i + 1
        }
        return ks
    }


    // _put writes key into the current table without ever resizing — the caller
    // guarantees a free slot. Shared by `add` and the rehash in `_resize`.
    fn _put(mut self, key: K) {
        let cap = self.slots.len()
        var i = self._index(key, cap)
        loop {
            match self.slots[i] {
                case Some(k) {
                    if k.eq(key) { return }       // already present — a set holds it once
                }
                case None {
                    self.slots[i] = Some(key)
                    self.count = self.count + 1
                    return
                }
            }
            i = (i + 1) % cap
        }
    }


    // _ensure_capacity lazily allocates the first table and doubles it once the
    // load factor (count/cap) would exceed 0.7, keeping probe chains short.
    fn _ensure_capacity(mut self) {
        let cap = self.slots.len()
        if cap == 0 {
            var i = 0
            loop {
                if i == 8 { return }
                self.slots.append(None)
                i = i + 1
            }
            return
        }
        if self.count * 10 >= cap * 7 {
            self._resize(cap * 2)
        }
    }


    // _resize rebuilds the table at newcap, rehashing every key. Existing keys are
    // snapshotted first so the slot array can be replaced cleanly.
    fn _resize(mut self, newcap: int) {
        var ks: [K] = []
        var j = 0
        loop {
            if j == self.slots.len() { break }
            match self.slots[j] {
                case Some(k) { ks.append(k) }
                case None { }
            }
            j = j + 1
        }
        var fresh: [Option<K>] = []
        var i = 0
        loop {
            if i == newcap { break }
            fresh.append(None)
            i = i + 1
        }
        self.slots = fresh
        self.count = 0
        var m = 0
        loop {
            if m == ks.len() { return }
            self._put(ks[m])
            m = m + 1
        }
    }
}
