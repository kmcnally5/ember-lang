// newtype_basic.em — OFI-149: a `type` declares a DISTINCT nominal type over a base, constructed
// with Name(x), at zero runtime cost. Here UserId/OrderId/Money all erase to int but are not
// interchangeable; a newtype value flows through let bindings, params, and returns.
type UserId = int
type OrderId = int
type Money = int

fn fee(m: Money) -> Money {
    return m
}

fn pick(u: UserId) -> int {
    return 0
}

fn main() -> int {
    let u: UserId = UserId(7)
    let o: OrderId = OrderId(42)
    let m: Money = fee(Money(500))
    return pick(u)
}
