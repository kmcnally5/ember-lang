// 03_errors.em — errors as values, no null. THE big improvement over FROG.
//
// FROG returned (value, err) tuples and you checked `if err != null`. That's explicit (good)
// but verbose and `null` is unsafe. Ember keeps the explicitness and adds:
//   - `Result<T, E>`  : Ok(value) or Err(error). No exceptions, no hidden control flow.
//   - `Option<T>`     : Some(value) or None. There is no `null` in Ember, at all.
//   - `?`             : propagate an error up one level, terse, with zero boilerplate.

import "std/string" as str

struct Config {
    host: string
    port: int
}

// Look up a `key = value` line in a config blob. Returns Result: the trimmed value,
// or an Err naming the missing key. This is the unit `?` propagates through below.
fn field(text: string, key: string) -> Result<string, string> {
    let lines = text.split("\n")
    for line in lines {
        let parts = line.split("=")
        if parts.len() == 2 {
            if str.trim(parts[0]) == key {
                return Ok(str.trim(parts[1]))
            }
        }
    }
    return Err("missing field: {key}")
}

fn parse_host(text: string) -> Result<string, string> {
    return field(text, "host")
}

fn parse_port(text: string) -> Result<int, string> {
    // `?` unwraps the Ok or returns the Err early — same error type, so it propagates.
    let raw = field(text, "port")?
    match raw.parse_int() {
        case Some(n) { return Ok(n) }
        case None    { return Err("port is not a number: {raw}") }
    }
}

// Returns Result: either an Ok(Config) or the first Err encountered.
fn load_config(text: string) -> Result<Config, string> {
    // `?` unwraps Ok, or returns early with the Err. This replaces FROG's repeated
    //     `let host, err = parse_host(text)  if err != null { return null, err }`
    let host = parse_host(text)?
    let port = parse_port(text)?
    return Ok(Config { host: host, port: port })
}

// Option for "might not be there" — never null.
fn find_user(id: int) -> Option<string> {
    if id == 1 { return Some("ada") }
    return None
}

fn main() {
    // You MUST handle both arms — the checker enforces it. No unchecked failures slip through.
    match load_config("host = example.com\nport = 8080\n") {
        case Ok(cfg)  { println("serving {cfg.host}:{cfg.port}") }
        case Err(msg) { println("config error: {msg}") }
    }

    // A config missing `port` — the `?` in load_config short-circuits to this Err arm.
    match load_config("host = solo\n") {
        case Ok(cfg)  { println("serving {cfg.host}:{cfg.port}") }
        case Err(msg) { println("config error: {msg}") }
    }

    match find_user(1) {
        case Some(name) { println("found {name}") }
        case None       { println("no such user") }
    }
}
