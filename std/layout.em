// std/layout — a small flexbox layout solver (MANIFESTO §5g). You build an EPHEMERAL tree of
// boxes for one frame, call solve() with the root rectangle, then read each box's computed rect.
// It is pure — ints, arrays, and structs, no rendering — so the layout maths is testable on its
// own (no window needed), and std/flare drives it to position real widgets.
//
// The model is flexbox, the layout vocabulary every LLM already knows: a container lays its
// children along a main axis (a `row` is horizontal, a `column` vertical), with `gap` between them
// and `pad` inside; `justify` distributes them along that axis (start / center / end / between) and
// `align` positions them across it (start / center / end / stretch); a child with `grow > 0` soaks
// up leftover main-axis space. The tree is rebuilt every frame and thrown away — nothing is
// retained — so it stays true to Ember's immediate-mode bet while giving real, nestable layout.
//
// The tree is index-linked (`nodes[i].next_sibling = c`), which leans on field-assignment through
// an array index — the thing OFI-061 unlocked. The language growing into itself.

let COL     = 0   // container main axis: top-to-bottom
let ROW     = 1   // container main axis: left-to-right

let START   = 0   // justify/align: pack at the start
let CENTER  = 1   // justify/align: centre
let END     = 2   // justify/align: pack at the end
let BETWEEN = 3   // justify only: first at start, last at end, even gaps between
let STRETCH = 3   // align only: fill the cross axis


// LNode is one box in the tree: structural links (indices, -1 = none), the flex inputs, the
// intrinsic content size measured bottom-up, and the final solved rectangle.
struct LNode {
    parent: int
    first_child: int
    last_child: int
    next_sibling: int

    leaf: bool        // true = a widget slot (intrinsic size is given), false = a container
    dir: int          // container main axis (COL / ROW)
    justify: int
    align: int
    gap: int
    pad: int
    grow: int         // flex-grow weight (0 = fixed to intrinsic size)
    no_stretch: bool  // a leaf that OPTS OUT of cross-axis STRETCH: keeps its intrinsic cross size
                      // (start-aligned) even inside a `stretch` parent — so an atomic action widget
                      // (a button) sizes to its content instead of spanning the column (OFI-115)

    float: bool       // a FLOATING node: skipped by its parent's flow, placed by solve()
    fw: int           // floating requested width  (0 = size to content)
    fh: int           // floating requested height (0 = size to content)
    fx: int           // floating anchor x (-1 = centre in the root); clamped on-screen when set
    fy: int           // floating anchor y (-1 = centre)

    cw: int           // intrinsic content width  (leaf: given; container: measured)
    ch: int           // intrinsic content height

    rx: int           // solved rectangle
    ry: int
    rw: int
    rh: int
}


// Layout owns the per-frame node array and the open-container cursor.
struct Layout {
    nodes: [LNode]
    cur: int          // the container currently open (top of the build stack); -1 before the root


    // reset clears the tree for a new frame.
    fn reset(mut self) {
        self.nodes = []
        self.cur = -1
    }


    // _link wires node `idx` in as the last child of the currently open container.
    fn _link(mut self, idx: int) {
        let p = self.nodes[idx].parent
        if p >= 0 {
            if self.nodes[p].first_child < 0 {
                self.nodes[p].first_child = idx
            } else {
                let lc = self.nodes[p].last_child
                self.nodes[lc].next_sibling = idx
            }
            self.nodes[p].last_child = idx
        }
    }


    // open starts a content-sized container (grow 0) and makes it current; returns its node index.
    // The first open() is the root. Pair every open() with a close().
    fn open(mut self, dir: int, justify: int, align: int, gap: int, pad: int) -> int {
        return self.open_grow(dir, justify, align, gap, pad, 0)
    }


    // open_grow is open() with an explicit flex-grow weight: a grow>0 container expands to fill its
    // share of leftover space along its PARENT's main axis (so a main pane fills the row a fixed
    // sidebar leaves, or a transcript fills the column above a pinned composer).
    fn open_grow(mut self, dir: int, justify: int, align: int, gap: int, pad: int, grow: int) -> int {
        let idx = self.nodes.len()
        self.nodes.append(LNode {
            parent: self.cur, first_child: -1, last_child: -1, next_sibling: -1,
            leaf: false, dir: dir, justify: justify, align: align, gap: gap, pad: pad, grow: grow,
            no_stretch: false, float: false, fw: 0, fh: 0, fx: -1, fy: -1,
            cw: 0, ch: 0, rx: 0, ry: 0, rw: 0, rh: 0
        })
        self._link(idx)
        self.cur = idx
        return idx
    }


    // open_float opens a FLOATING container: it is NOT flowed by its parent (skipped in measure and
    // place), and solve() instead CENTRES it in the root box at (fw, fh) — or its measured content
    // size when fw/fh are 0. This is the basis for overlays that sit above the normal flow: modals,
    // popovers, toasts. Declared wherever in the tree is convenient; it always lands centred on the
    // window. Pair every open_float() with a close().
    fn open_float(mut self, dir: int, justify: int, align: int, gap: int, pad: int, fw: int, fh: int) -> int {
        let idx = self.nodes.len()
        self.nodes.append(LNode {
            parent: self.cur, first_child: -1, last_child: -1, next_sibling: -1,
            leaf: false, dir: dir, justify: justify, align: align, gap: gap, pad: pad, grow: 0,
            no_stretch: false, float: true, fw: fw, fh: fh, fx: -1, fy: -1,
            cw: 0, ch: 0, rx: 0, ry: 0, rw: 0, rh: 0
        })
        self._link(idx)
        self.cur = idx
        return idx
    }


    // open_float_at is open_float ANCHORED at (fx, fy) instead of centred — a context menu / popover that
    // pops up near the cursor or a trigger. solve() places it there, clamped so it stays fully on-screen.
    fn open_float_at(mut self, dir: int, justify: int, align: int, gap: int, pad: int, fx: int, fy: int, fw: int, fh: int) -> int {
        let idx = self.nodes.len()
        self.nodes.append(LNode {
            parent: self.cur, first_child: -1, last_child: -1, next_sibling: -1,
            leaf: false, dir: dir, justify: justify, align: align, gap: gap, pad: pad, grow: 0,
            no_stretch: false, float: true, fw: fw, fh: fh, fx: fx, fy: fy,
            cw: 0, ch: 0, rx: 0, ry: 0, rw: 0, rh: 0
        })
        self._link(idx)
        self.cur = idx
        return idx
    }


    // _leaf adds a fixed-size slot (a widget) of intrinsic size (w, h) with a flex-grow weight and an
    // explicit cross-axis-stretch opt-out. Returns its node index (so the caller can read its rect).
    fn _leaf(mut self, w: int, h: int, grow: int, no_stretch: bool) -> int {
        let idx = self.nodes.len()
        self.nodes.append(LNode {
            parent: self.cur, first_child: -1, last_child: -1, next_sibling: -1,
            leaf: true, dir: COL, justify: START, align: START, gap: 0, pad: 0, grow: grow,
            no_stretch: no_stretch, float: false, fw: 0, fh: 0, fx: -1, fy: -1,
            cw: w, ch: h, rx: 0, ry: 0, rw: 0, rh: 0
        })
        self._link(idx)
        return idx
    }


    // leaf adds a widget slot that FILLS the cross axis under a `stretch` parent (text, dividers — they
    // want to span to wrap / rule). Pair with leaf_fixed for content-sized widgets.
    fn leaf(mut self, w: int, h: int, grow: int) -> int {
        return self._leaf(w, h, grow, false)
    }


    // leaf_fixed adds a widget slot pinned to its intrinsic cross size — it will NOT stretch to fill a
    // `stretch` parent (an atomic action widget like a button sizes to its content, OFI-115).
    fn leaf_fixed(mut self, w: int, h: int, grow: int) -> int {
        return self._leaf(w, h, grow, true)
    }


    // close finishes the current container, returning to its parent.
    fn close(mut self) {
        if self.cur >= 0 {
            self.cur = self.nodes[self.cur].parent
        }
    }


    // _main / _cross give a child's intrinsic size along the parent's main and cross axes.
    fn _main(self, parent: int, child: int) -> int {
        if self.nodes[parent].dir == ROW {
            return self.nodes[child].cw
        }
        return self.nodes[child].ch
    }


    fn _cross(self, parent: int, child: int) -> int {
        if self.nodes[parent].dir == ROW {
            return self.nodes[child].ch
        }
        return self.nodes[child].cw
    }


    // _measure computes every container's intrinsic content size from its children. It walks nodes
    // in REVERSE creation order, so a node's children (created after it) are already sized when it
    // is reached: a container's main extent is the sum of child main sizes plus gaps, its cross
    // extent the largest child cross size, both plus its own padding.
    fn _measure(mut self) {
        var i = self.nodes.len() - 1
        loop {
            if i < 0 {
                break
            }
            if !self.nodes[i].leaf {
                var main = 0
                var cross = 0
                var count = 0
                var c = self.nodes[i].first_child
                loop {
                    if c < 0 {
                        break
                    }
                    if self.nodes[c].float {           // a floating child does not size its parent
                        c = self.nodes[c].next_sibling
                        continue
                    }
                    main = main + self._main(i, c)
                    let cc = self._cross(i, c)
                    if cc > cross {
                        cross = cc
                    }
                    count = count + 1
                    c = self.nodes[c].next_sibling
                }
                if count > 1 {
                    main = main + self.nodes[i].gap * (count - 1)
                }
                let p2 = self.nodes[i].pad * 2
                if self.nodes[i].dir == ROW {
                    self.nodes[i].cw = main + p2
                    self.nodes[i].ch = cross + p2
                } else {
                    self.nodes[i].ch = main + p2
                    self.nodes[i].cw = cross + p2
                }
            }
            i = i - 1
        }
    }


    // _place positions container `i`'s children inside its solved content box (its rect minus
    // padding), honouring justify (main axis), align (cross axis), gap, and grow, then recurses.
    fn _place(mut self, i: int) {
        if self.nodes[i].leaf {
            return
        }
        let pad = self.nodes[i].pad
        let bx = self.nodes[i].rx + pad
        let by = self.nodes[i].ry + pad
        let bw = self.nodes[i].rw - pad * 2
        let bh = self.nodes[i].rh - pad * 2
        let dir = self.nodes[i].dir

        var avail = bh
        var crossbox = bw
        if dir == ROW {
            avail = bw
            crossbox = bh
        }

        // Tally children: total intrinsic main size, count, and grow weight.
        var used = 0
        var count = 0
        var growsum = 0
        var c = self.nodes[i].first_child
        loop {
            if c < 0 {
                break
            }
            if self.nodes[c].float {              // floating children are placed separately, not in flow
                c = self.nodes[c].next_sibling
                continue
            }
            used = used + self._main(i, c)
            growsum = growsum + self.nodes[c].grow
            count = count + 1
            c = self.nodes[c].next_sibling
        }
        var gaps = 0
        if count > 1 {
            gaps = self.nodes[i].gap * (count - 1)
        }
        let free = avail - used - gaps

        // Starting offset + inter-child spacing from justify (only meaningful when nothing grows).
        var cursor = 0
        var between = self.nodes[i].gap
        if growsum == 0 {
            if self.nodes[i].justify == CENTER {
                cursor = free / 2
            } else if self.nodes[i].justify == END {
                cursor = free
            } else if self.nodes[i].justify == BETWEEN {
                if count > 1 {
                    between = self.nodes[i].gap + free / (count - 1)
                }
            }
        }

        c = self.nodes[i].first_child
        loop {
            if c < 0 {
                break
            }
            if self.nodes[c].float {              // skip floats here; solve() places them centred
                c = self.nodes[c].next_sibling
                continue
            }
            var cmain = self._main(i, c)
            if growsum > 0 {
                if self.nodes[c].grow > 0 {
                    cmain = cmain + (free * self.nodes[c].grow) / growsum
                }
            }
            // Cross-axis size + offset from align.
            var ccross = self._cross(i, c)
            var crossoff = 0
            if self.nodes[i].align == CENTER {
                crossoff = (crossbox - ccross) / 2
            } else if self.nodes[i].align == END {
                crossoff = crossbox - ccross
            } else if self.nodes[i].align == STRETCH {
                if !self.nodes[c].no_stretch {       // a no_stretch leaf keeps its intrinsic cross size (OFI-115)
                    ccross = crossbox
                }
            }
            if dir == ROW {
                self.nodes[c].rx = bx + cursor
                self.nodes[c].ry = by + crossoff
                self.nodes[c].rw = cmain
                self.nodes[c].rh = ccross
            } else {
                self.nodes[c].ry = by + cursor
                self.nodes[c].rx = bx + crossoff
                self.nodes[c].rh = cmain
                self.nodes[c].rw = ccross
            }
            cursor = cursor + cmain + between
            self._place(c)
            c = self.nodes[c].next_sibling
        }
    }


    // solve assigns every node's rect, given the root box. Call after building the tree.
    fn solve(mut self, x: int, y: int, w: int, h: int) {
        if self.nodes.len() == 0 {
            return
        }
        self._measure()
        self.nodes[0].rx = x
        self.nodes[0].ry = y
        self.nodes[0].rw = w
        self.nodes[0].rh = h
        self._place(0)
        // Floating nodes were skipped by the flow above. Give each its requested size (or its measured
        // content size when 0), centre it in the root box, and place its own subtree within it.
        var i = 1
        loop {
            if i == self.nodes.len() {
                break
            }
            if self.nodes[i].float {
                var fw = self.nodes[i].fw
                var fh = self.nodes[i].fh
                if fw <= 0 {
                    fw = self.nodes[i].cw
                }
                if fh <= 0 {
                    fh = self.nodes[i].ch
                }
                var px = x + (w - fw) / 2          // centred by default
                var py = y + (h - fh) / 2
                if self.nodes[i].fx >= 0 {          // anchored: place at (fx,fy), clamped fully on-screen
                    px = self.nodes[i].fx
                    py = self.nodes[i].fy
                    if px + fw > x + w {
                        px = x + w - fw
                    }
                    if py + fh > y + h {
                        py = y + h - fh
                    }
                    if px < x {
                        px = x
                    }
                    if py < y {
                        py = y
                    }
                }
                self.nodes[i].rx = px
                self.nodes[i].ry = py
                self.nodes[i].rw = fw
                self.nodes[i].rh = fh
                self._place(i)
            }
            i = i + 1
        }
    }


    // Accessors for the solved rectangle of node `i` (read by the renderer / hit-testing).
    fn x(self, i: int) -> int {
        return self.nodes[i].rx
    }
    fn y(self, i: int) -> int {
        return self.nodes[i].ry
    }
    fn w(self, i: int) -> int {
        return self.nodes[i].rw
    }
    fn h(self, i: int) -> int {
        return self.nodes[i].rh
    }


    // content_h is node `i`'s INTRINSIC content height (what its children measured to), independent of
    // the height it was solved to. A scroll viewport compares this to its solved height to learn how
    // far its content overflows.
    fn content_h(self, i: int) -> int {
        return self.nodes[i].ch
    }
}


// new creates an empty layout.
fn new() -> Layout {
    return Layout { nodes: [], cur: -1 }
}
