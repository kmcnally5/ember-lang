// error_duplicate_type.em — two top-level types sharing a name in one module are
// rejected (structs and enums share the type namespace), so a type reference can
// never silently resolve to the wrong declaration (OFI-008).
struct Point { x: int  y: int }
enum Point { Origin  Other }
fn main() -> int { return 0 }
