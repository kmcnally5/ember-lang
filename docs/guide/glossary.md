---
title: "Appendix A — Glossary"
parent: "Guide"
nav_order: 7
---

# Appendix A — Glossary

**Binding** — a name attached to a value, via `let` (immutable) or `var` (mutable).

**Borrow** — using a value without taking ownership of it; the default for parameters.

**Closure** — a function value that has captured variables from where it was created (by value,
in Ember).

**Contract** — a `requires`/`ensures` specification attached to a function; checked in debug,
elided in release.

**Dynamic dispatch** — calling a method through an interface *value*, where the concrete type
isn't known until runtime and the right method is found via the value's method table (vtable).
Contrast with a generic *bound*, which dispatches statically through a witness.

**Enum** — a sum type: a value that is exactly one of several named variants, each possibly
carrying typed fields.

**Exhaustive** — a `match` that handles every variant; required, and checked by the compiler.

**Generic** — code parameterised by type (`Box<T>`), written once and used for many types.

**Interface** — a named set of method signatures a type can declare it `implements`.

**Move** — transferring ownership of a value; the old name can't be used afterward.

**Nursery** — a scoped block that owns concurrent tasks and joins them all before it exits.

**Object-safe** — an interface whose methods only ever mention `Self` as the receiver (never as a
parameter or return type), which is the condition for using it as a value type for dynamic
dispatch. Non-object-safe interfaces are still usable as generic bounds.

**Option** — `Some(value)` or `None`; Ember's "maybe a value," replacing `null`.

**Prelude** — the handful of types (`Option`, `Result`) injected into every program
automatically.

**Result** — `Ok(value)` or `Err(error)`; a success-or-reasoned-failure value.

**Tape** — the structured, per-instruction JSON record of an execution.

**Unit function** — a function with no return type; it runs for effect and yields no value.
