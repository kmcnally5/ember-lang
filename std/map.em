// std/map.em — a generic hash map Map<K: Hash + Eq, V>, written in Ember. Open
// addressing with linear probing over a bucket array; an empty slot is the prelude's
// `None`, an occupied one a `Some(MapEntry)`. The table starts empty and grows lazily,
// doubling whenever it passes a 0.7 load factor, so operations are amortised O(1). A
// `get` miss returns `None`.
//
// The key type K need only satisfy Hash + Eq. Built-in scalars, strings, and enums qualify
// natively; a user struct that `implements Hash, Eq` is also a valid key (OFI-042). A move-type
// key (struct/array) needs no `Copy` bound: storing it deep-clones structurally (the runtime's
// own_into_slot, the same clone that makes aggregates-through-generics sound), so the map owns its
// copy and the caller keeps theirs — value-semantic keys with no `clone()` ceremony. hash/eq are
// dispatched through witnesses the map stores per instance, so the same compiled code serves every
// key type. `_index` clears the hash's sign bit so a user `hash()` returning a negative int can't
// trap the probe.
//   Import it:  import "std/map" as mp  ->  mp.Map<string, int>{ buckets: [], count: 0 }
// MapEntry just stores a key/value pair — it never hashes or compares, so its K needs
// no bound. (Map below carries the Hash + Eq bound and does the dispatching.)
struct MapEntry<K, V> {
    key: K
    val: V
}






// The key type K must be Hash + Eq (to bucket and compare). The map stores, probes, and rehashes
// keys; a built-in key (scalar/string/enum) copies cheaply, and a move-type struct key is
// deep-cloned structurally on store (sound, no double-free — verified VM==native + ASan).
struct Map<K: Hash + Eq, V> {
    buckets: [Option<MapEntry<K, V>>]
    count: int


    // size returns the number of stored keys.
    fn size(self) -> int {
        return self.count
    }


    // _index maps a key to its starting bucket. The sign bit is cleared (matching the
    // native hasher, vm.c NATIVE_HASH_ANY) so a user `Hash` impl that returns a NEGATIVE
    // int can never produce a negative `% cap` index — which would trap with "array index
    // out of bounds". Computed once per operation; the probe walks on with `(i + 1) % cap`.
    fn _index(self, key: K, cap: int) -> int {
        return (key.hash() & 9223372036854775807) % cap
    }


    // has reports whether key is present. Probing stops at the first empty slot,
    // which always exists because the load factor is kept below 1.
    fn has(self, key: K) -> bool {
        if self.buckets.len() == 0 { return false }
        let cap = self.buckets.len()
        var i = self._index(key, cap)
        loop {
            match self.buckets[i] {
                case Some(e) { if e.key.eq(key) { return true } }
                case None { return false }
            }
            i = (i + 1) % cap
        }
        return false
    }


    // get returns Some(value) for key, or None if it is absent.
    fn get(self, key: K) -> Option<V> {
        if self.buckets.len() == 0 { return None }
        let cap = self.buckets.len()
        var i = self._index(key, cap)
        loop {
            match self.buckets[i] {
                case Some(e) { if e.key.eq(key) { return Some(e.val) } }
                case None { return None }
            }
            i = (i + 1) % cap
        }
        return None
    }


    // set inserts or updates key -> val, growing the table first if needed.
    fn set(mut self, key: K, val: V) {
        self._ensure_capacity()
        self._put(key, val)
    }


    // keys returns every stored key (in bucket order, not insertion order).
    fn keys(self) -> [K] {
        var ks: [K] = []
        var i = 0
        loop {
            if i == self.buckets.len() { return ks }
            match self.buckets[i] {
                case Some(e) { ks.append(e.key) }
                case None { }
            }
            i = i + 1
        }
        return ks
    }


    // remove deletes key, returning true if it was present. Linear-probe deletion can't just
    // null the slot — that would sever the probe chain for any key that collided here and was
    // pushed further along (a later get would stop at the hole and miss it). So we null it, then
    // re-home every entry in the contiguous cluster that FOLLOWS it (via _put, which never
    // resizes), restoring the "a None ends the probe" invariant. Snapshotting the cluster before
    // reinserting mirrors _resize's discipline, and dropping each cleared Some(entry) releases
    // the removed key + val exactly once.
    fn remove(mut self, key: K) -> bool {
        if self.buckets.len() == 0 { return false }
        let cap = self.buckets.len()
        var idx = -1
        var i = self._index(key, cap)
        loop {
            match self.buckets[i] {
                case Some(e) { if e.key.eq(key) { idx = i  break } }
                case None { break }
            }
            i = (i + 1) % cap
        }
        if idx == -1 { return false }
        var ks: [K] = []
        var vs: [V] = []
        var j = (idx + 1) % cap
        loop {
            match self.buckets[j] {
                case None { break }
                case Some(e) {
                    ks.append(e.key)
                    vs.append(e.val)
                    self.buckets[j] = None
                    self.count = self.count - 1
                }
            }
            j = (j + 1) % cap
        }
        self.buckets[idx] = None
        self.count = self.count - 1
        var m = 0
        loop {
            if m == ks.len() { break }
            self._put(ks[m], vs[m])
            m = m + 1
        }
        return true
    }


    // _put writes key -> val into the current table without ever resizing — the
    // caller guarantees a free slot. Shared by `set` and the rehash in `_resize`.
    fn _put(mut self, key: K, val: V) {
        let cap = self.buckets.len()
        var i = self._index(key, cap)
        loop {
            match self.buckets[i] {
                case Some(e) {
                    if e.key.eq(key) {
                        self.buckets[i] = Some(MapEntry<K, V> { key: key, val: val })
                        return
                    }
                }
                case None {
                    self.buckets[i] = Some(MapEntry<K, V> { key: key, val: val })
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
        let cap = self.buckets.len()
        if cap == 0 {
            var i = 0
            loop {
                if i == 8 { return }
                self.buckets.append(None)
                i = i + 1
            }
            return
        }
        if self.count * 10 >= cap * 7 {
            self._resize(cap * 2)
        }
    }


    // _resize rebuilds the table at newcap, rehashing every entry. Existing keys
    // and values are snapshotted first so the bucket array can be replaced cleanly.
    fn _resize(mut self, newcap: int) {
        var ks: [K] = []
        var vs: [V] = []
        var j = 0
        loop {
            if j == self.buckets.len() { break }
            match self.buckets[j] {
                case Some(e) { ks.append(e.key)  vs.append(e.val) }
                case None { }
            }
            j = j + 1
        }
        var fresh: [Option<MapEntry<K, V>>] = []
        var i = 0
        loop {
            if i == newcap { break }
            fresh.append(None)
            i = i + 1
        }
        self.buckets = fresh
        self.count = 0
        var m = 0
        loop {
            if m == ks.len() { return }
            self._put(ks[m], vs[m])
            m = m + 1
        }
    }
}
