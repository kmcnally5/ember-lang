// in_module.em (fault) — OFI-111a: the divide-by-zero traps inside the imported divmod module, so
// the Fault's file must be the MODULE's path (tests/fault/modlib/divmod.em), not this entry file.
import "modlib/divmod" as dm
fn main() -> int {
    return dm.divide(10, 0)
}
