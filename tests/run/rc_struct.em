// rc_struct.em — regression for `rc struct` (Rc-of-immutable): shared ownership without move or
// clone, deep nesting (an rc field whose type is another rc struct), sharing into an array and a
// plain struct, and an immutable persistent cons-list with structural sharing. All owners of one
// value name a single heap object (refcounted), reclaimed at the last drop — verified leak-free /
// double-drop-free elsewhere; here we assert behavior and VM==native parity.
import "std/slotmap" as sm

rc struct Name {
    first: string
    last: string
}

rc struct Person {
    name: Name        // an rc field whose type is ANOTHER rc struct (nesting)
    age: int
}

struct Holder {       // a plain (mutable) struct may hold an rc value by reference
    who: Person
    tag: int
}

rc struct Cons {
    head: int
    tail: Option<Cons>
}

fn cost(p: Person) -> int {
    return p.age      // pass-by-borrow of a shared rc value
}

fn sum(node: Option<Cons>) -> int {
    match node {
        case Some(c) { return c.head + sum(c.tail) }
        case None    { return 0 }
    }
}

fn main() -> int {
    let n  = Name { first: "Ada", last: "Lovelace" }
    let p1 = Person { name: n, age: 36 }     // p1 shares n
    let p2 = Person { name: n, age: 99 }     // p2 shares n too — n now has 3 owners
    print("p1=({p1.name.first} {p1.name.last}, {p1.age})  cost(p2)={cost(p2)}\n")

    let p1b = p1                             // a second owner of p1: incref, NOT move — p1 stays live
    print("p1 still live after binding: {p1.age}, alias {p1b.age}\n")

    var people: [Person] = []
    people.append(p1)
    people.append(p2)
    people.append(p1)                        // p1 shared into the array twice
    var total = 0
    var i = 0
    loop {
        if i == people.len() { break }
        total = total + people[i].age
        i = i + 1
    }
    print("array len={people.len()} total_age={total}\n")

    let holder = Holder { who: p2, tag: 7 }
    print("holder=({holder.who.name.first}, age {holder.who.age}, tag {holder.tag})\n")

    var arena = sm.SlotMap<Person>{ items: [], gen: [], free: [], count: 0 }
    let h = arena.insert(p1)
    match arena.get(h) {
        case Some(q) { print("arena={q.name.first}, age {q.age}\n") }
        case None    { print("arena miss\n") }
    }

    // Persistent cons-list with structural sharing: listA and listB share the same suffix node.
    let shared = Cons { head: 30, tail: None }
    let a = Cons { head: 10, tail: Some(shared) }
    let b = Cons { head: 20, tail: Some(shared) }
    let listA = Cons { head: 1, tail: Some(a) }
    let listB = Cons { head: 2, tail: Some(b) }
    print("sumA={sum(Some(listA))} sumB={sum(Some(listB))}\n")
    return total
}
