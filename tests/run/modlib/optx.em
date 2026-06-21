// modlib/optx.em — an imported library module whose API speaks the prelude's
// Option<T>. It never imports or declares Option: the prelude is global, so an
// imported module sees it unqualified exactly like the entry module does.
fn first_positive(a: int, b: int) -> Option<int> {
    if a > 0 {
        return Some(a)
    }
    if b > 0 {
        return Some(b)
    }
    return None
}
