// array_field_checkout.em — locks the two language primitives the OFI-072 workaround relies on.
// A struct holding an array field is a BOXED array element (unlike the all-scalar inline-value case
// in array_struct_inline.em), so you can't move its array field out and can't append through the
// index. The Claude app's in-memory multi-conversation routes around that with a "checkout":
//   (1) whole-array WRITE-BACK through an index — convos[i].msgs = work — must PERSIST, and
//   (2) slice(0, len) copies an array field OUT — work = convos[i].msgs.slice(...) — INDEPENDENT.
// (The OFI-072 no-op itself — convos[i].msgs.append(x) silently losing the write — is deliberately
// NOT asserted here, so a future fix that makes it work won't fail this regression.)
struct Conv {
    tag: string
    msgs: [string]
}


fn main() -> int {
    var convos: [Conv] = []
    convos.append(Conv { tag: "a", msgs: [] })
    convos.append(Conv { tag: "b", msgs: [] })

    // build a working buffer, then write the WHOLE array back through the index
    var work: [string] = []
    work.append("one")
    work.append("two")
    convos[0].msgs = work                                     // (1) array write-back through index
    convos[0].tag = "filled"                                  // scalar write-back through index

    // copy OUT via slice, then mutate the copy — the stored array must NOT change
    var out = convos[0].msgs.slice(0, convos[0].msgs.len())   // (2) independent copy out
    out.append("three")

    println("store={convos[0].msgs.len()} copy={out.len()} tag={convos[0].tag}")
    println("store0={convos[0].msgs[0]} store1={convos[0].msgs[1]}")
    println("other={convos[1].msgs.len()}")
    return 0
}
