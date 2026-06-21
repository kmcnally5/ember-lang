#!/bin/sh
# Build the net+graphics compiler (libcurl + raylib) and run the Flare Claude app.
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./run-flare.sh   (runs without a key too — sending just reminds you)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
make net-graphics >/dev/null
exec build/emberc-net-gfx --emit=run public/claude-desktop/flare_chat.em
