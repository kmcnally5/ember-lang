#!/bin/sh
# Build the M:N net+graphics compiler (libcurl + raylib + the M:N green-thread scheduler, OFI-071)
# and run the Flare Claude app ON the M:N scheduler — the dogfood soak that earns the default flip.
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./run-flare-mn.sh   (runs without a key too — sending just reminds you)
#
# Sibling of run-flare.sh, which uses the proven 1:1 thread-per-fiber build (build/emberc-net-gfx).
# NOTE: the fetch worker's http_post is a BLOCKING libcurl FFI call, so it parks its worker OS thread
# for the request (not just the fiber) — fine with >=2 cores; the render loop keeps running elsewhere.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
make mn-net-graphics >/dev/null
exec build/emberc-mn-net-gfx --emit=run public/claude-desktop/flare_chat.em
