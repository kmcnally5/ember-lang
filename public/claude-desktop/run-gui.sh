#!/bin/sh
# Build the net+graphics compiler (libcurl + raylib) and run the Claude Desktop GUI.
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./run-gui.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
make net-graphics >/dev/null
exec build/emberc-net-gfx --emit=run public/claude-desktop/gui.em
