// enum_err_payload.em (fault) — OFI-111b: an Err whose payload is itself an ENUM renders by variant
// name with its nested (quoted) data (`NotFound("/etc/hosts")`), not the old `<obj>`.
enum FileError {
    NotFound(path: string)
    Locked(by: int)
}

fn open() -> Result<int, FileError> {
    return Err(NotFound("/etc/hosts"))
}

fn main() -> Result<int, FileError> {
    let fd = open()?
    return Ok(fd)
}
