// generic_struct_pack.em — each concrete generic struct instance gets its own
// packed layout (Step 2.5): Box<u8> packs its field to 1 byte, Box<i32> to 4,
// Box<i64> to 8, while Box<string> keeps a 16-byte boxed pointer. Field access
// resolves the right offset/width through the instance's own descriptor, so the
// values round-trip correctly regardless of how tightly they are packed.
struct Box<T> { value: T }

fn unwrap_u8(b: Box<u8>) -> i32 { return i32(b.value) }

fn main() -> int {
    let a = Box<u8>  { value: 250 }       // packed to 1 byte
    let b = Box<i32> { value: 1000000 }   // packed to 4 bytes
    let c = Box<i64> { value: 9000000000 }// packed to 8 bytes
    let d = Box<string> { value: "ok" }   // boxed (16 bytes)
    println("{a.value} {b.value} {c.value} {d.value}")
    return i64(unwrap_u8(a)) + i64(b.value) + (c.value % 1000)  // 250+1000000+0
}
