// control_flow.em — locks statement shapes: if / else-if / else chains, for-in,
// loop with break, continue, match with patterns, and nursery/spawn.

fn flow(x: int) {
    if x < 0 {
        return
    } else if x == 0 {
        loop {
            break
        }
    } else {
        for i in [1, 2, 3] {
            continue
        }
    }

    match x {
        case Some(v) {
            spawn work(v)
        }
        case None {
            nursery {
                spawn a()
                spawn b()
            }
        }
    }
}
