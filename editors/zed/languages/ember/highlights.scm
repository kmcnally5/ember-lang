; Ember syntax highlighting for Zed (tree-sitter). The grammar (tree-sitter-ember) is intentionally
; lexical-depth only — it tokenizes; it does not re-parse Ember's semantics (the C compiler is the
; one frontend). So this query colours tokens, and recovers `fn name` / `struct Name` heads from
; adjacent-sibling patterns. Zed applies LATER patterns with higher precedence, so the general
; `(identifier) @variable` is listed before the more specific type/function recoveries.

(keyword) @keyword
(boolean) @boolean
(self) @variable.builtin
(primitive_type) @type.builtin
(builtin) @function.builtin

(string) @string
(number) @number
(line_comment) @comment

(operator) @operator
(punctuation) @punctuation.delimiter

; Identifiers: default to variable, then let the specific recoveries below override.
(identifier) @variable

; A Capitalized identifier reads as a type (struct/enum/interface name, type reference).
((identifier) @type
  (#match? @type "^[A-Z]"))

; Declaration heads — `fn name`, `struct Name`, `enum Name`, `interface Name` — recovered from the
; keyword immediately followed by its name (`.` = adjacent siblings in the flat token stream).
((keyword) @_kw . (identifier) @function
  (#eq? @_kw "fn"))
((keyword) @_kw . (identifier) @type
  (#eq? @_kw "struct"))
((keyword) @_kw . (identifier) @type
  (#eq? @_kw "enum"))
((keyword) @_kw . (identifier) @type
  (#eq? @_kw "interface"))
