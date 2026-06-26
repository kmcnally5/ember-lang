// struct_err_payload.em (fault) — OFI-111b: an Err whose payload is a STRUCT renders its fields as
// data (`ParseError { line: 3, msg: "bad token" }`) on the agent Fault, not the old `<obj>`.
struct ParseError {
    line: int
    msg: string
}

fn parse() -> Result<int, ParseError> {
    return Err(ParseError { line: 3, msg: "bad token" })
}

fn main() -> Result<int, ParseError> {
    let n = parse()?
    return Ok(n)
}
