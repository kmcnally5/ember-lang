// error_method_arity.em — wrong number of explicit arguments to a method.
struct C { v: int  fn add(self, x: int) -> int { return self.v + x } }
fn main() -> int { let c = C { v: 1 }  return c.add() }
