// string_param.em — strings as parameters and return values.
fn greet(name: string) -> string {
    return "Hi " + name
}
fn main() -> string {
    return greet("Karl")
}
