fn main() {
    var i = 0
    var x = 0

    let start = clock()

    loop {
        if i == 1000000000 {
            break
        }

        x = x + 1
        i = i + 1
    }

    println(clock() - start)
}