// newtype.em — OFI-149 differential: a newtype erases to its base on BOTH backends. Compare, show,
// and unwrap-for-arithmetic must produce byte-identical stdout from the VM and the native binary.
type Celsius = int
type Tag     = string

fn main() -> int {
    let lo: Celsius = Celsius(10)
    let hi: Celsius = Celsius(30)
    println("lo<hi={lo < hi} eq={lo == lo} hi={hi}")
    let span: Celsius = Celsius(int(hi) - int(lo))
    println("span={span}")
    let t: Tag = Tag("ok")
    let same: Tag = Tag("ok")
    println("tag={t} same={t == same}")
    return 0
}
