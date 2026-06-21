// 06_calculator.em — an arithmetic expression evaluator, end to end: a string is
// tokenized into a list of tokens, parsed by recursive descent into an expression
// tree, and evaluated. It exercises much of Ember at once — a recursive `enum`
// (the syntax tree), exhaustive `match`, generics-backed growable arrays, the
// string methods (`chars`, `parse_int`), the prelude's `Option` (no declaration
// needed), and a `mut self` struct carrying parser state.
//
// Grammar (standard precedence, left-associative, with parentheses):
//   expr   := term   (('+' | '-') term)*
//   term   := factor (('*' | '/') factor)*
//   factor := number | '(' expr ')'


// ---- Tokens ----

enum Token {
    TNum(value: int)
    TPlus
    TMinus
    TStar
    TSlash
    TLParen
    TRParen
}


// Scan a source string into a list of tokens. Numbers may be multi-digit;
// whitespace is skipped. A character is a digit exactly when it parses as an int.
fn tokenize(src: string) -> [Token] {
    var tokens: [Token] = []
    let cs = src.chars()
    var i = 0
    var num = 0
    var in_num = false
    loop {
        if i == cs.len() {
            if in_num { tokens.append(TNum(num)) }
            return tokens
        }
        let c = cs[i]
        match c.parse_int() {
            case Some(d) {
                num = num * 10 + d
                in_num = true
            }
            case None {
                if in_num {
                    tokens.append(TNum(num))
                    num = 0
                    in_num = false
                }
                if c == "+" { tokens.append(TPlus) }
                else if c == "-" { tokens.append(TMinus) }
                else if c == "*" { tokens.append(TStar) }
                else if c == "/" { tokens.append(TSlash) }
                else if c == "(" { tokens.append(TLParen) }
                else if c == ")" { tokens.append(TRParen) }
                else { }                     // skip spaces and anything else
            }
        }
        i = i + 1
    }
    return tokens
}


// ---- Syntax tree ----

enum Expr {
    Num(value: int)
    Add(left: Expr, right: Expr)
    Sub(left: Expr, right: Expr)
    Mul(left: Expr, right: Expr)
    Div(left: Expr, right: Expr)
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


// ---- Recursive-descent parser ----

struct Parser {
    tokens: [Token]
    pos: int

    // The kind of the current token as a small tag, or -1 at end of input.
    fn kind(self) -> int {
        if self.pos >= self.tokens.len() { return -1 }
        match self.tokens[self.pos] {
            case TNum(v)  { return 0 }
            case TPlus    { return 1 }
            case TMinus   { return 2 }
            case TStar    { return 3 }
            case TSlash   { return 4 }
            case TLParen  { return 5 }
            case TRParen  { return 6 }
        }
        return -1
    }

    fn advance(mut self) {
        self.pos = self.pos + 1
    }

    fn parse_factor(mut self) -> Expr {
        if self.pos >= self.tokens.len() { return Num(0) }
        match self.tokens[self.pos] {
            case TNum(v)  { self.advance()  return Num(v) }
            case TLParen  {
                self.advance()              // consume '('
                let inner = self.parse_expr()
                self.advance()              // consume ')'
                return inner
            }
            case _ { return Num(0) }        // malformed input — degrade gracefully
        }
        return Num(0)
    }

    fn parse_term(mut self) -> Expr {
        var left = self.parse_factor()
        loop {
            let k = self.kind()
            if k == 3 {                     // '*'
                self.advance()
                let r = self.parse_factor()
                left = Mul(left, r)
            } else if k == 4 {              // '/'
                self.advance()
                let r = self.parse_factor()
                left = Div(left, r)
            } else {
                return left
            }
        }
        return left
    }

    fn parse_expr(mut self) -> Expr {
        var left = self.parse_term()
        loop {
            let k = self.kind()
            if k == 1 {                     // '+'
                self.advance()
                let r = self.parse_term()
                left = Add(left, r)
            } else if k == 2 {              // '-'
                self.advance()
                let r = self.parse_term()
                left = Sub(left, r)
            } else {
                return left
            }
        }
        return left
    }
}


fn calc(src: string) -> int {
    var p = Parser { tokens: tokenize(src), pos: 0 }
    return eval(p.parse_expr())
}


fn main() -> int {
    println("3 + 4 * 2        = {calc("3 + 4 * 2")}")          // 11
    println("(3 + 4) * 2      = {calc("(3 + 4) * 2")}")        // 14
    println("100 / 5 - 3      = {calc("100 / 5 - 3")}")        // 17
    println("2 * (3 + 4) * 5  = {calc("2 * (3 + 4) * 5")}")    // 70
    println("1 + 2 + 3 + 4    = {calc("1 + 2 + 3 + 4")}")      // 10
    return calc("(1 + 2) * (3 + 4)")                           // 21
}
