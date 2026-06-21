// use_prelude_module.em — proves the prelude (Option/Result) is globally visible:
// an imported module (modlib/optx) both returns and constructs Option<int> without
// importing it, and this entry module matches on the result it gets back. The
// prelude lives in its own always-in-scope module, so every module shares it.
import "modlib/optx" as optx
fn main() -> int {
    match optx.first_positive(0, 42) {
        case Some(n) { return n }       // => 42
        case None { return -1 }
    }
}
