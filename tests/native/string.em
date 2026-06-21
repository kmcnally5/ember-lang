// Native backend (M2) differential test: strings (boxed, refcounted, immutable).
// Literals, concatenation (+), interpolation, println output, == comparison, and .len(),
// plus a string param and return.

fn greet(name: string) -> string {
    return "Hello, " + name + "!"
}

fn main() -> int {
    let who = "Ember"
    let msg = greet(who)
    println(msg)
    println("len = {msg.len()}")
    let n = 42
    println("the answer is {n}")
    if msg == "Hello, Ember!" {
        println("match ok")
    }
    return msg.len()
}
