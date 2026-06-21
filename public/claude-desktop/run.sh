#!/bin/sh
# Build the net-enabled compiler (libcurl) and run the Claude CLI.
# Usage: ./run.sh "your message"
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
make net >/dev/null
exec build/emberc-net --emit=run public/claude-desktop/chat.em "$@"
