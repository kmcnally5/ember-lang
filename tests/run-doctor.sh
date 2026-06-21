#!/bin/sh
# tests/run-doctor.sh — regression for `emberc --doctor`, the setup health-check. A newcomer's first
# encounter with a broken setup must be a CLEAR, FIXABLE message, not a mystery (one unexplained
# failure and they give up). So assert that a healthy build passes (exit 0, all-clear) and that a
# broken stdlib is caught with the fix shown and a non-zero exit.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc"
[ -x "$BIN" ] || { echo "skip: $BIN not built — run 'make' first"; exit 0; }

# Healthy: the repo build resolves ../std → every check passes, exit 0.
out=$(EMBER_STD="$ROOT/std" "$BIN" --doctor) || {
    echo "FAIL: --doctor exited non-zero on a healthy setup"; echo "$out"; exit 1; }
echo "$out" | grep -q "All essential checks passed" || {
    echo "FAIL: healthy --doctor is missing the all-clear line"; echo "$out"; exit 1; }
echo "$out" | grep -q "compiler frontend  self-test passed" || {
    echo "FAIL: healthy --doctor is missing the frontend self-test"; echo "$out"; exit 1; }

# Broken stdlib: must be CAUGHT, advise the fix, and exit non-zero.
out=$(EMBER_STD="/nonexistent-ember-std-dir" "$BIN" --doctor); rc=$?
[ "$rc" -ne 0 ] || {
    echo "FAIL: --doctor should exit non-zero when the stdlib cannot be found"; exit 1; }
echo "$out" | grep -q "standard library  NOT FOUND" || {
    echo "FAIL: a missing stdlib was not reported"; echo "$out"; exit 1; }
echo "$out" | grep -q "make install" || {
    echo "FAIL: the missing-stdlib message should suggest \`make install\`"; echo "$out"; exit 1; }

# --version prints one line; --help shows usage with the SAME version (one constant, no drift).
ver=$("$BIN" --version) || { echo "FAIL: --version exited non-zero"; exit 1; }
echo "$ver" | grep -q "^emberc " || {
    echo "FAIL: --version should print 'emberc <version>', got: $ver"; exit 1; }
"$BIN" --help | grep -q "usage:" || { echo "FAIL: --help is missing the usage block"; exit 1; }
"$BIN" --help | grep -qF "$ver" || {
    echo "FAIL: --help header version should match --version ($ver)"; exit 1; }

echo "doctor: passed — healthy setup all-clear; broken stdlib caught with a fix + non-zero exit;"
echo "        --version / --help consistent ($ver)"
