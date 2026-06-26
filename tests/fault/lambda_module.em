// lambda_module.em (fault) — OFI-111a: the trap happens inside a lambda DEFINED in the imported lam
// module, so the Fault's file must be tests/fault/modlib/lam.em, not this entry file.
import "modlib/lam" as lam
fn main() -> int {
    return lam.run(10, 0)
}
