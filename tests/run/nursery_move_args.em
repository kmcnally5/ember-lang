// nursery_move_args.em — a spawned task takes ownership of its arguments (`move`).
struct Job { id: int }
fn run_job(move j: Job) -> int {
    println(j.id)
    return 0
}
fn main() -> int {
    nursery {
        spawn run_job(Job { id: 10 })
        spawn run_job(Job { id: 20 })
    }
    return 0
}
