// Regression for std/sse — the Server-Sent Events decoder behind std/http streaming. Feeds synthetic
// Anthropic events in chunks, INCLUDING one delta split across a chunk boundary ("Hel" + "lo"), and
// prints the framed events. Proves: events are framed on the blank line, a partial event is buffered
// across feeds and reassembled, and event/data fields are parsed. (Literal JSON braces in these test
// strings are escaped \{ \} — the runtime SSE data has real braces and needs no escaping.)
import "std/sse" as sse

fn dump(label: string, evs: [sse.Event]) {
    println(label)
    var i = 0
    loop {
        if i == evs.len() {
            break
        }
        println("  [{evs[i].name}] {evs[i].data}")
        i = i + 1
    }
}

fn main() -> int {
    var d = sse.decoder()
    dump("c1", d.feed("event: message_start\ndata: \{\"type\":\"message_start\"\}\n\nevent: content_block_delta\ndata: \{\"text\":\"Hel"))
    dump("c2", d.feed("lo\"\}\n\nevent: content_block_delta\ndata: \{\"text\":\" world\"\}\n\n"))
    dump("c3", d.feed("event: message_stop\ndata: \{\}\n\n"))
    return 0
}
