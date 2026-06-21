// modlib/mathx.em — an imported library module. `square`/`cube` are public;
// `_step` is private (leading underscore) and usable only within this module.
fn _step(n: int) -> int { return n + 1 }
fn square(n: int) -> int { return n * n }
fn cube(n: int) -> int { return square(n) * _step(n - 1) }
