// tests/run/json_records.em — regression for the DESERIALIZE pattern flare_chat's persistence uses: parse a
// JSON array of objects (each with a scalar + an ARRAY field) and rebuild a [Struct] from it via
// json.length/at/as_*. Stresses struct + array construction from parsed data (kernel-relevant: aggregate
// serialization). JSON braces/quotes are escaped `\{ \} \"` (Ember's `{` opens interpolation, `"` ends a string).
import "std/json" as json

struct Rec { name: string  tags: [string] }

fn main() -> int {
    let src = "[\{\"name\": \"a\", \"tags\": [\"x\", \"y\"]\}, \{\"name\": \"b\", \"tags\": []\}]"
    var recs: [Rec] = []
    match json.parse(src) {
        case Ok(v) {
            var i = 0
            loop {
                if i == json.length(v) {
                    break
                }
                let o = json.at(v, i)
                let tj = json.get(o, "tags")
                var ts: [string] = []
                var k = 0
                loop {
                    if k == json.length(tj) {
                        break
                    }
                    ts.append(json.as_str(json.at(tj, k)))
                    k = k + 1
                }
                recs.append(Rec { name: json.as_str(json.get(o, "name")), tags: ts })
                i = i + 1
            }
        }
        case Err(m) { println("ERR {m}") }
    }
    var i = 0
    loop {
        if i == recs.len() {
            break
        }
        let tags = recs[i].tags.slice(0, recs[i].tags.len())
        println("{recs[i].name}: {tags.len()} tags = {concat(tags)}")
        i = i + 1
    }
    return 0
}
