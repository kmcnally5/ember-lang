// exit_code.em — exit(code) halts execution immediately: the line after it does not run,
// and main's return value is NOT printed (the program ends with the given code).
fn main() -> int {
    println("before exit")
    exit(0)
    println("after exit")   // unreachable
    return 99               // not reached; satisfies definite-return
}
