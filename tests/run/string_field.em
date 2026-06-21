// string_field.em — a string-typed struct field, read back out.
struct Tag {
    label: string
    n: int
}
fn main() -> string {
    let t = Tag { label: "id", n: 5 }
    return t.label
}
