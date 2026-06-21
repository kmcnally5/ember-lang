/// A 2-D point in the plane.
/// Copied by value; both fields are public.
struct Point {
    /// The horizontal coordinate.
    x: int
    /// The vertical coordinate.
    y: int

    /// The squared distance from the origin.
    /// Avoids a sqrt when only ordering matters.
    fn dist2(self) -> int {
        return self.x * self.x + self.y * self.y
    }
}

/// The colours a traffic light can show.
enum Light {
    /// Stop.
    Red
    /// Get ready.
    Amber
    /// Go.
    Green
}

/// A thing that can report its area.
interface Shape {
    /// The area enclosed by the shape.
    fn area(self) -> float
}

/// Add two integers and return their sum.
fn add(a: int, b: int) -> int {
    return a + b
}

// An ordinary comment that must never reach the docs.
/// The maximum supported width, in pixels.
let max_width = 1024
