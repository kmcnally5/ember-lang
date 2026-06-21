// for_strings.em — arrays of any element type; iterate and concatenate.
fn main() -> string {
    let words = ["Hello", ", ", "Ember"]
    var out = ""
    for w in words {
        out = out + w
    }
    return out
}
