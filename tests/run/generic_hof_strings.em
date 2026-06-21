// generic_hof_strings.em — regression for the OFI-015 runtime crash class: mixed
// instantiations of generic higher-order functions with refcounted (string)
// elements. Two bugs lived here: (1) a closure called inside an erased generic
// body released argument references nobody added (OP_CALL_CLOSURE now retains heap
// arguments at run time), and (2) an erased element store (sort's shift
// `out[j] = out[j-1]`) aliased a string into two slots with one count (consume now
// marks type-param reads for a conditional OP_INCREF). Both underflows freed values
// the caller still owned — so this test deliberately KEEPS using the source arrays
// after the closure calls, which crashed before the fixes.
import "std/list" as list
fn gtwice<T>(f: fn(T) -> T, x: T) -> T { return f(f(x)) }
fn main() -> int {
    let nums = [1, 2, 3, 4]
    let n = 10
    let scaled = list.map(nums, |x| x * n)                  // [10, 20, 30, 40]
    let words = ["delta", "al", "char", "bee"]
    let lens = list.map(words, |w| w.len())                 // [5, 2, 4, 3]
    let bylen = list.sort(words, |a, b| a.len() < b.len())  // [al, bee, char, delta]
    println(words[0])                                       // delta — source intact
    println(bylen[0])                                       // al
    let shout = gtwice(|s| s + "!", "hi")                   // "hi!!"
    println(shout)
    // 40 + (5+2+4+3) + 2 + 4 = 60
    let lensum = lens[0] + lens[1] + lens[2] + lens[3]
    return scaled[3] + lensum + bylen[0].len() + shout.len()
}
