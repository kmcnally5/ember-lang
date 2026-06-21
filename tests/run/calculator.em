// calculator.em — integration regression for the expression evaluator (the full
// showcase lives in examples/06_calculator.em). Tokenize → recursive-descent parse
// (precedence + parens) → evaluate. Exercises recursive enums, exhaustive match,
// growable arrays, string methods, the prelude's Option, and a mut self parser.
enum Token { TNum(value: int)  TPlus  TMinus  TStar  TSlash  TLParen  TRParen }

enum Expr {
    Num(value: int)
    Add(left: Expr, right: Expr)
    Sub(left: Expr, right: Expr)
    Mul(left: Expr, right: Expr)
    Div(left: Expr, right: Expr)
}

fn tokenize(src: string) -> [Token] {
    var ts: [Token] = []
    let cs = src.chars()
    var i = 0
    var num = 0
    var in_num = false
    loop {
        if i == cs.len() {
            if in_num { ts.append(TNum(num)) }
            return ts
        }
        let c = cs[i]
        match c.parse_int() {
            case Some(d) { num = num * 10 + d  in_num = true }
            case None {
                if in_num { ts.append(TNum(num))  num = 0  in_num = false }
                if c == "+" { ts.append(TPlus) }
                else if c == "-" { ts.append(TMinus) }
                else if c == "*" { ts.append(TStar) }
                else if c == "/" { ts.append(TSlash) }
                else if c == "(" { ts.append(TLParen) }
                else if c == ")" { ts.append(TRParen) }
                else { }
            }
        }
        i = i + 1
    }
    return ts
}

fn eval(e: Expr) -> int {
    match e {
        case Num(v)    { return v }
        case Add(l, r) { return eval(l) + eval(r) }
        case Sub(l, r) { return eval(l) - eval(r) }
        case Mul(l, r) { return eval(l) * eval(r) }
        case Div(l, r) { return eval(l) / eval(r) }
    }
    return 0
}

struct Parser {
    tokens: [Token]
    pos: int

    fn kind(self) -> int {
        if self.pos >= self.tokens.len() { return -1 }
        match self.tokens[self.pos] {
            case TNum(v) { return 0 }   case TPlus { return 1 }
            case TMinus  { return 2 }   case TStar { return 3 }
            case TSlash  { return 4 }   case TLParen { return 5 }
            case TRParen { return 6 }
        }
        return -1
    }
    fn advance(mut self) { self.pos = self.pos + 1 }

    fn factor(mut self) -> Expr {
        if self.pos >= self.tokens.len() { return Num(0) }
        match self.tokens[self.pos] {
            case TNum(v)  { self.advance()  return Num(v) }
            case TLParen  { self.advance()  let e = self.expr()  self.advance()  return e }
            case _        { return Num(0) }
        }
        return Num(0)
    }
    fn term(mut self) -> Expr {
        var left = self.factor()
        loop {
            let k = self.kind()
            if k == 3 { self.advance()  let r = self.factor()  left = Mul(left, r) }
            else if k == 4 { self.advance()  let r = self.factor()  left = Div(left, r) }
            else { return left }
        }
        return left
    }
    fn expr(mut self) -> Expr {
        var left = self.term()
        loop {
            let k = self.kind()
            if k == 1 { self.advance()  let r = self.term()  left = Add(left, r) }
            else if k == 2 { self.advance()  let r = self.term()  left = Sub(left, r) }
            else { return left }
        }
        return left
    }
}

fn calc(src: string) -> int {
    var p = Parser { tokens: tokenize(src), pos: 0 }
    return eval(p.expr())
}

fn main() -> int {
    var total = 0
    total = total + calc("3 + 4 * 2")          // 11
    total = total + calc("(3 + 4) * 2")        // 14
    total = total + calc("100 / 5 - 3")        // 17
    total = total + calc("2 * (3 + 4) * 5")    // 70
    total = total + calc("(1 + 2) * (3 + 4)")  // 21
    return total                               // 133
}
