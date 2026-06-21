// use_modules.em — imports a library module and calls its public functions
// module-qualified (mathx.square). Privacy and cross-module resolution are
// exercised by modlib/mathx.em.
import "modlib/mathx" as mathx
fn main() -> int {
    return mathx.square(5) + mathx.cube(2)   // 25 + (4 * 2) = 33
}
