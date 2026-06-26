#!/usr/bin/env python3
# tools/tape-cmp.py — tolerant comparison of a graphics tape against its golden (OFI-068).
#
# The graphics goldens are exact text dumps of the UI tape. The font itself is pinned (Inter is
# embedded in the binary), but the FreeType *library version* rasterises it with slightly different
# metrics, so a glyph advance — and every layout x/width derived from it — can shift +/-1px between
# machines. An exact string compare then fails a golden that is structurally identical, which is the
# whole of OFI-068 ("goldens should tolerate font-version drift or pin the font").
#
# This compares frame-by-frame as JSON and requires the STRUCTURE to match exactly — same frames, same
# draw ops in order, same op type / layer / colour / size / alpha / text — while allowing the POSITION
# and SIZE fields (x, y, w, h) of each draw to differ by up to TOL pixels (default 3, $EMBER_TAPE_TOL).
# The mouse field is ignored (it is the environmental cursor position). Anything the comparator cannot
# parse as JSON (an error line) falls back to an exact match, so a genuine error still fails loudly.
#
# Usage:  tape-cmp.py <golden-file> <actual-file>   ->  exit 0 if equivalent, 1 + a one-line reason.
# Wired into tests/run-graphics.sh; a missing python3 falls back to the exact string compare there.
import sys, os, re, json

TOL = int(os.environ.get("EMBER_TAPE_TOL", "3"))
# Only these per-draw fields are font-metric-derived and may drift; everything else is exact.
TOL_KEYS = {"x", "y", "w", "h"}


def load(path):
    with open(path) as f:
        return [ln.rstrip("\n") for ln in f if ln.strip() != ""]


def parse(line):
    # The harness rewrites the mouse coords to the non-JSON placeholder [_,_]; restore a numeric value
    # so json can parse the line (the mouse field is ignored in the comparison regardless).
    return json.loads(re.sub(r'"mouse":\[[^\]]*\]', '"mouse":[0,0]', line))


def frame_diff(g, a):
    if g.get("frame") != a.get("frame"):
        return "frame {} vs {}".format(g.get("frame"), a.get("frame"))
    fr = g.get("frame")
    if g.get("down") != a.get("down"):
        return "frame {}: down {} vs {}".format(fr, g.get("down"), a.get("down"))
    gd, ad = g.get("draws", []), a.get("draws", [])
    if len(gd) != len(ad):
        return "frame {}: {} draws vs {}".format(fr, len(gd), len(ad))
    for i, (go, ao) in enumerate(zip(gd, ad)):
        if go.keys() != ao.keys():
            return "frame {} draw {}: keys {} vs {}".format(fr, i, sorted(go), sorted(ao))
        for k in go:
            gv, av = go[k], ao[k]
            if k in TOL_KEYS and isinstance(gv, (int, float)) and isinstance(av, (int, float)):
                if abs(gv - av) > TOL:
                    return "frame {} draw {} [{}] {}: {} vs {} (> {}px)".format(
                        fr, i, go.get("op"), k, gv, av, TOL)
            elif gv != av:
                return "frame {} draw {} [{}] {}: {!r} vs {!r}".format(fr, i, go.get("op"), k, gv, av)
    return None


def main():
    if len(sys.argv) != 3:
        print("usage: tape-cmp.py <golden> <actual>")
        return 2
    golden, actual = load(sys.argv[1]), load(sys.argv[2])
    if len(golden) != len(actual):
        print("tape-cmp: {} frame(s) vs {}".format(len(golden), len(actual)))
        return 1
    for g, a in zip(golden, actual):
        try:
            go, ao = parse(g), parse(a)
        except ValueError:
            if g != a:                       # a non-JSON line (e.g. an error) → exact
                print("tape-cmp: line differs: {!r} vs {!r}".format(g, a))
                return 1
            continue
        msg = frame_diff(go, ao)
        if msg is not None:
            print("tape-cmp: " + msg)
            return 1
    return 0


sys.exit(main())
