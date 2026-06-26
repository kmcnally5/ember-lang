// newtype_ops.em — OFI-149 Stage 2: a newtype inherits its base's compare / hash / show (Karl's
// chosen v1 set), so UserIds compare, sort, work as Map keys, and interpolate; arithmetic is via
// an explicit unwrap (int(x)). String-base newtypes (Email) compare + render too.
import "std/map" as mp

type UserId = int
type Money  = int
type Email  = string

fn main() -> int {
    let a: UserId = UserId(7)
    let b: UserId = UserId(7)
    let c: UserId = UserId(9)
    println("eq={a == b} neq={a == c} lt={a < c} id={a}")

    let sum: Money = Money(int(Money(500)) + int(Money(250)))   // unwrap, add, re-wrap
    println("total={sum}")

    let e1: Email = Email("a@x.io")
    let e2: Email = Email("a@x.io")
    println("email_eq={e1 == e2} addr={e1}")

    var users = mp.Map<UserId, string> { buckets: [], count: 0 }
    users.set(UserId(7), "alice")
    match users.get(UserId(7)) {
        case Some(name) { println("u7={name}") }
        case None { println("missing") }
    }
    return 0
}
