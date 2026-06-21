// std/sse — a Server-Sent Events decoder (the streaming layer for std/http; design: docs/http-design.md).
// Feed it raw HTTP-body chunks as they arrive; it returns the COMPLETE events framed so far and buffers
// the trailing partial across feeds. SSE frames events with a blank line ("\n\n"); within an event,
// `event:` names it and one or more `data:` lines carry the payload. This turns Ember's streaming HTTP
// body (the http_open/http_next pull) into a clean Channel-of-events the app reads — e.g. Claude's
// token-by-token `content_block_delta`s. Pure string work: no graphics, no net, runs anywhere.
import "std/string" as str

// A decoded SSE event: its `event:` name and the concatenated `data:` payload.
struct Event {
    name: string
    data: string
}


// _starts reports whether `line` begins with the ASCII prefix `pfx`.
fn _starts(line: string, pfx: string) -> bool {
    let n = str.cp_count(pfx)
    if str.cp_count(line) < n {
        return false
    }
    return str.cp_slice(line, 0, n) == pfx
}


// _after returns `line` with its first `pfx_len` code points removed, then one optional leading space
// stripped — the SSE field value after "event:" / "data:".
fn _after(line: string, pfx_len: int) -> string {
    var s = str.cp_slice(line, pfx_len, str.cp_count(line))
    if str.cp_count(s) > 0 && str.cp_slice(s, 0, 1) == " " {
        s = str.cp_slice(s, 1, str.cp_count(s))
    }
    return s
}


// _parse turns one complete event block (its lines) into an Event. Unknown fields (id:, retry:, :comments)
// are tolerated and ignored — forward-compatible per the SSE spec.
fn _parse(block: string) -> Event {
    var name = ""
    var data = ""
    let lines = block.split("\n")
    var i = 0
    loop {
        if i == lines.len() {
            break
        }
        let line = lines[i]
        if _starts(line, "event:") {
            name = _after(line, 6)
        } else if _starts(line, "data:") {
            let d = _after(line, 5)
            if data.len() > 0 {
                data = data + "\n" + d
            } else {
                data = d
            }
        }
        i = i + 1
    }
    return Event { name: name, data: data }
}


// Decoder holds the bytes received but not yet framed into a complete event.
struct Decoder {
    buf: string


    // feed appends `chunk` and returns every event now COMPLETE (terminated by a blank line); the
    // trailing partial event stays buffered for the next feed. An event may span chunk boundaries.
    fn feed(mut self, chunk: string) -> [Event] {
        self.buf = self.buf + chunk
        let blocks = self.buf.split("\n\n")
        var events: [Event] = []
        var i = 0
        loop {
            if i == blocks.len() - 1 {       // the last block is the (possibly empty) partial tail
                break
            }
            let ev = _parse(blocks[i])
            if ev.name.len() > 0 || ev.data.len() > 0 {
                events.append(ev)
            }
            i = i + 1
        }
        self.buf = blocks[blocks.len() - 1]
        return events
    }
}


// decoder makes a fresh SSE decoder. Hold it across the whole streamed response.
fn decoder() -> Decoder {
    return Decoder { buf: "" }
}
