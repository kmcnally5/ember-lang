// literals.em — number and string literal edge cases.
// Locks the tricky scanner decisions: integer vs float, the float look-ahead
// that keeps `obj.field` as DOT rather than swallowing the dot, escape handling,
// and the rule that interpolation braces stay inside the STRING lexeme for the
// parser to split out later.

let i        = 0
let big      = 1000000
let f        = 3.14159
let zero     = 0.0
let member   = obj.field
let chained  = a.b.c
let plain    = "plain string"
let escaped  = "tab\tnewline\nquote\" slash\\"
let interp   = "x = {x}, y = {y}"
let empty    = ""
