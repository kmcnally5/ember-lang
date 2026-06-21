// Native backend differential test: structs with HEAP fields (string/array) are boxed and
// refcounted like the VM (value-type C structs are only for all-scalar structs). Exercises
// construction, a method reading a heap field, field reassignment (drops the old value), a
// heap-field struct moved into and read back from a function, and one stored/returned — the
// paths that previously leaked because such a struct was wrongly a value-type C struct.
struct Config {
    host: string
    port: int
}

fn describe(move c: Config) -> string {
    return c.host
}

fn main() -> int {
    var c = Config { host: "example.com", port: 8080 }
    println("host {c.host} port {c.port}")
    c.host = "localhost"                 // reassign a heap field (old dropped)
    c.port = 9090
    println("host {c.host} port {c.port}")
    let h = describe(Config { host: "other.org", port: 1 })
    println("desc {h}")
    return c.host.len() + c.port
}
