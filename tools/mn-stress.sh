#!/bin/sh
# tools/mn-stress.sh — the M:N green-thread scheduler stress/scaling harness (OFI-071).
#
# Crucible's / Ledger's / Ceilings' sibling, aimed at the CONCURRENCY-CORRECTNESS class the M:N
# scheduler introduces (a worker pool multiplexing many cooperatively-yielding fibers, with parking
# channels + structured cancellation). It GENERATES danger-zone concurrent programs with a KNOWN
# deterministic answer (a checksum, never output ordering — that is legitimately nondeterministic
# under real parallelism) and runs each under build/emberc-mn with a WATCHDOG: a hang (timeout) is a
# failure, a wrong answer is a failure, a wrong exit code is a failure. The headline case is the proof
# the model works at all: spawn THOUSANDS of fibers in one nursery and complete — a count the 1:1
# pthread-per-spawn build cannot create as OS threads.
#
# Usage:  tools/mn-stress.sh            run the suite
#         tools/mn-stress.sh -v         verbose (show each program's output)
#
# Exit 0 iff every case passes. Wired into `make mn-stress` and `make verify`.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc-mn"
export EMBER_STD="$ROOT/std"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1
WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT
TIMEOUT=60

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make mn' first"
    exit 0
fi

pass=0
fail=0

# run <name> <expected-stdout-substring> <expected-exit> <file.em>
# Runs with a watchdog; a timeout (124/137/142) is reported as a HANG failure.
run_case() {
    name="$1"; want="$2"; wantec="$3"; src="$4"
    out=$(timeout "$TIMEOUT" "$BIN" --emit=run "$src" 2>&1)
    ec=$?
    [ "$VERBOSE" -eq 1 ] && printf '    [%s] exit=%s out=%s\n' "$name" "$ec" "$(printf '%s' "$out" | tr '\n' ' ')"
    if [ "$ec" -eq 124 ] || [ "$ec" -eq 137 ] || [ "$ec" -eq 142 ]; then
        echo "FAIL $name — HANG (watchdog fired at ${TIMEOUT}s)"
        fail=$((fail + 1))
        return
    fi
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL $name — wanted output containing '$want', got: $(printf '%s' "$out" | tr '\n' ' ')"
        fail=$((fail + 1))
        return
    fi
    if [ "$ec" -ne "$wantec" ]; then
        echo "FAIL $name — wanted exit $wantec, got $ec"
        fail=$((fail + 1))
        return
    fi
    pass=$((pass + 1))
}

# ---- HEADLINE: thousands of cheap fibers in one nursery (1:1 would need thousands of OS threads) ----
cat > "$WD/many.em" <<'EOF'
fn work(ch: Channel<int>, n: int) { send(ch, n) }
fn main() -> int {
    let ch: Channel<int> = channel(64)
    var total = 0
    let N = 8000
    nursery {
        var i = 0
        loop { if i == N { break } spawn work(ch, 1) i = i + 1 }
        var got = 0
        loop {
            if got == N { break }
            match recv(ch) { case Some(v) { total = total + v } case None { break } }
            got = got + 1
        }
    }
    print("total={total}\n")
    return 0
}
EOF
run_case "headline-8000-fibers" "total=8000" 0 "$WD/many.em"

# ---- fan-out / fan-in compute: each task returns work via a channel, summed (deterministic) ----
cat > "$WD/fanio.em" <<'EOF'
fn worker(ch: Channel<int>, base: int) {
    var s = 0
    var i = 0
    loop { if i == 1000 { break } s = s + (base + i) i = i + 1 }
    send(ch, s)
}
fn main() -> int {
    let ch: Channel<int> = channel(8)
    var total = 0
    nursery {
        var w = 0
        loop { if w == 16 { break } spawn worker(ch, w * 1000) w = w + 1 }
        var got = 0
        loop { if got == 16 { break } match recv(ch) { case Some(v) { total = total + v } case None {} } got = got + 1 }
    }
    print("total={total}\n")
    return 0
}
EOF
# sum over w in 0..15 of sum_{i=0..999}(w*1000+i) = 16*(999*1000/2) + 1000*1000*(0+..+15)
#   = 16*499500 + 1000000*120 = 7992000 + 120000000 = 127992000
run_case "fan-in-out-compute" "total=127992000" 0 "$WD/fanio.em"

# ---- deep nested nurseries (divide & conquer): each level spawns two children ----
cat > "$WD/nested.em" <<'EOF'
fn leaf(ch: Channel<int>, v: int) { send(ch, v) }
fn main() -> int {
    let ch: Channel<int> = channel(4)
    var total = 0
    nursery {
        spawn leaf(ch, 1)
        nursery {
            spawn leaf(ch, 10)
            nursery {
                spawn leaf(ch, 100)
                spawn leaf(ch, 1000)
            }
        }
        var got = 0
        loop { if got == 4 { break } match recv(ch) { case Some(v) { total = total + v } case None {} } got = got + 1 }
    }
    print("total={total}\n")
    return 0
}
EOF
run_case "nested-nurseries" "total=1111" 0 "$WD/nested.em"

# ---- deadlock: a task waits on a channel nobody fills/closes → global deadlock, report + exit, NO hang ----
cat > "$WD/deadlock.em" <<'EOF'
enum Option<T> { Some(value: T) None }
fn waiter(ch: Channel<int>) -> Option<int> { return recv(ch) }
fn main() -> int {
    let ch: Channel<int> = channel(1)
    nursery { spawn waiter(ch) }
    return 0
}
EOF
run_case "deadlock-detected" "deadlock: every task in the nursery is blocked" 65 "$WD/deadlock.em"

# ---- structured cancellation: one task errors → its siblings are cancelled, error reported, NO hang ----
cat > "$WD/cancel.em" <<'EOF'
fn boom(ch: Channel<int>) { var x = 9223372036854775807  x = x + 1  send(ch, x) }
fn waiter(ch: Channel<int>) { match recv(ch) { case Some(v) {} case None {} } }
fn main() -> int {
    let ch: Channel<int> = channel(1)
    nursery { spawn boom(ch)  spawn waiter(ch) }
    print("unreachable\n")
    return 0
}
EOF
run_case "cancel-on-error" "integer overflow" 65 "$WD/cancel.em"

# ---- pipeline: producer → consumer over a small channel, with close() ending the stream ----
cat > "$WD/pipe.em" <<'EOF'
fn producer(ch: Channel<int>) {
    var i = 0
    loop { if i == 500 { break } send(ch, i) i = i + 1 }
    close(ch)
}
fn main() -> int {
    let ch: Channel<int> = channel(8)
    var total = 0
    nursery {
        spawn producer(ch)
        loop { match recv(ch) { case Some(v) { total = total + v } case None { break } } }
    }
    print("total={total}\n")
    return 0
}
EOF
# sum_{i=0..499} i = 499*500/2 = 124750
run_case "pipeline-with-close" "total=124750" 0 "$WD/pipe.em"

# ---- OFI-138/089: main PARKS at the nursery join (the body ends while a child is still in flight),
# ---- then RESUMES. The main fiber is PINNED to worker 0, so its resume lands on the calling thread —
# ---- the GL-context thread for a GUI app, where the prior bug ran teardown off-context (SEGV). A lost
# ---- wakeup in the pinned-slot routing would manifest here as a HANG (the watchdog fires). ----
cat > "$WD/join_park.em" <<'EOF'
fn worker(ch: Channel<int>) {
    var s = 0
    var i = 0
    loop { if i == 3000000 { break } s = s + 1 i = i + 1 }
    send(ch, s)
}
fn main() -> int {
    let ch: Channel<int> = channel(1)
    var got = 0
    nursery {
        spawn worker(ch)
        // body ends immediately → main parks at the join while the worker is still computing
    }
    match recv(ch) { case Some(v) { got = v } case None { got = 0 - 1 } }
    print("got={got}\n")
    return 0
}
EOF
run_case "main-parks-at-join" "got=3000000" 0 "$WD/join_park.em"

echo "mn-stress: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
