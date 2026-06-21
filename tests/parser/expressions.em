// expressions.em — locks operator precedence, postfix chains, try, arrays,
// grouping, unary, and (non-generic) struct literals in the parsed tree.

struct P {
    x: int
}

fn exprs() {
    let a = 1 + 2 * 3 - 4 / 2 % 2
    let b = a == 1 && a != 2 || !false
    let c = -a
    let d = obj.field.method(1, 2)[0]
    let e = risky()?
    let f = [1, 2, 3]
    let g = P { x: 5 }
    let h = (a + 1) * 2
}
