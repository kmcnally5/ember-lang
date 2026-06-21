// 15_wordcount.em — a real tool built on the new generic hash map. Counts how often
// each word appears across the command-line arguments, then prints the tallies.
//
//   emberc --emit=run examples/15_wordcount.em the cat the dog the cat
//     -> the: 3 / cat: 2 / dog: 1   (bucket order)
//
// Map<string, int> is the generic std/map; the same map type works for int keys, etc.

import "std/map" as mp

fn main() {
    let words = args()
    var counts = mp.Map<string, int> { buckets: [], count: 0 }

    for w in words {
        var n = 0
        match counts.get(w) {
            case Some(c) { n = c }
            case None    { n = 0 }
        }
        counts.set(w, n + 1)
    }

    println("{counts.size()} distinct word(s):")
    for key in counts.keys() {
        match counts.get(key) {
            case Some(c) { println("  {key}: {c}") }
            case None    { }
        }
    }
}
