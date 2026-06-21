# Flare — declarative, component-style UI for Ember

`std/flare` is Ember's React-style UI layer, built on `std/ui`'s immediate-mode widgets
(MANIFESTO §5g). It gives you React's *ergonomics* — components as functions, props, local
state, declarative composition — without React's machinery.

## Why there's no Virtual DOM

React's Virtual DOM and reconciler exist for one reason: the real DOM is **retained**, and
mutating it is expensive, so React diffs a cheap description against the previous one and patches
the minimum. Ember's backend **redraws the whole frame every tick, cheaply** — so that machinery
solves a problem Ember doesn't have. What's left of React once you remove the vtree is exactly its
good part, and it maps straight onto Ember's `loop { …describe the frame… }`. No retained tree, no
graph-shaped mutable state, so the ownership model stays clean — and the result is *more* legible
for an LLM than React.

## The mapping

| React | Flare |
|---|---|
| `function C(props) { return <jsx/> }` | `fn C(mut f: flare.Flare, props…) { …emit… }` |
| `<button onClick={fn}>` | `if f.button("Save") { … }` — events are **return values** |
| `useState(0)` | a plain `var` the loop owns (often no hook needed) |
| encapsulated `useState` | `f.state_int(key, dflt)` … `f.set_int(key, v)` |
| `key={id}` in a list | `f.key("row{i}")` — scopes widget ids **and** state |
| props | typed function arguments (checked at compile time) |
| context | the threaded `Flare` value |

The quiet win: React forces `useState` everywhere because a re-running function has nowhere stable
to keep state. In Ember **the loop owns your state as ordinary `var`s**, so `state_*` is only for
state you want *encapsulated* inside a reusable component.

## Identity (`key`) — the one concept that makes lists work

Immediate-mode widgets are identified by a hash of their label, so two components each with a `"+"`
button would collide. `f.key("apples")` / `f.key("pears")` open an **id scope** that is mixed into
every widget id *and* every piece of state under it — so the same-labelled widgets stay distinct.
This is React's `key` and the IMGUI id-stack, unified into one idea. Call `f.key_clear()` after a
keyed component or list.

## Example — a counter component

```rust
import "std/draw" as draw
import "std/flare" as flare

fn Counter(mut f: flare.Flare, key: string, title: string) {
    f.key(key)
    var n = f.state_int("n", 0)
    f.row(flare.START, flare.CENTER)
    if f.button("-") { n = n - 1 }
    f.label("{title}: {n}")
    if f.button("+") { n = n + 1 }
    f.end()
    f.set_int("n", n)
    f.key_clear()
}

fn main() -> int {
    draw.window(420, 340, "Flare")
    var f = flare.new()
    loop {
        if draw.closing() { break }
        draw.begin(f.bg())
        f.begin()
        f.heading("Counters")
        Counter(f, "apples", "Apples")    // same "+"/"-" labels, kept apart by key()
        Counter(f, "pears",  "Pears")
        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
```

A full app built on Flare — a switchable conversation list, a scrollable transcript, a composer, and a
settings **modal** of **segmented** controls — is [`public/claude-desktop/flare_chat.em`](../public/claude-desktop/flare_chat.em).

## API (v1)

Lifecycle: `new()`, `begin()`, `finish()`, `bg()`, `use_dark()/use_light()`, `set_zoom(pct)` (the app-wide
text size, clamped 60–220 — pick an optimal default at startup, e.g. `f.set_zoom(80)`) / `zoom_by(delta)`.
Identity: `key(s)`, `key_clear()`.
State: `state_int/str/bool(key, dflt)` and `set_int/str/bool(key, v)`.
Layout (a REAL flexbox — `std/layout`): `row(justify, align)`, `column(justify, align)` size to content;
`row_grow/column_grow(justify, align)` flex to fill the parent's main axis; `spacer()` (flexible gap),
`strut(w, h)` (fixed min size, e.g. to pin a sidebar width); `panel_begin(justify, align)` (a container
with a painted surface); `bubble_begin()/bubble_end()` (a rounded, tinted message container — a chat
bubble, rounder than a panel); `page_begin(width)/page_end()` (a CENTRED, fixed-`width` content column with
flexible margins both sides — a readable "page", like CSS `max-width` + `margin: auto`); `scroll_begin(key)/scroll_end(key)` (a clipped, wheel-scrolled viewport) —
or `scroll_begin_sticky(key)` for a CHAT transcript: it follows the bottom as content grows but only while
you're already there, so scrolling up to read leaves you put (and scrolling back re-engages) — plus
`scroll_fab(key) -> bool` (a round "jump to latest" button that appears bottom-right when that area is
scrolled up — wire it to `scroll_to_bottom(key)`). Close every opener with `end()` (scroll/panel/bubble
close with their own end). Constants: `COL/ROW`, `START/CENTER/
END/BETWEEN`, `STRETCH`.
Overlays: `modal_begin(key, w, h) -> bool` / `modal_end()` open a **centred floating dialog** over a
dimmed scrim (`h = 0` sizes to content). While it is open the widgets *behind* it go inert (clicks can't
fall through), and a press on the scrim — outside the panel — returns `false`, the caller's cue to close
it. Build the contents as a column between the two calls. This rests on `std/layout`'s floating node, so
it always lands centred on the window regardless of where in the tree it is declared (the reusable basis
for settings dialogs, confirmations, and pickers).
`popover_begin(key, x, y) -> bool` / `popover_end()` open an **anchored** floating menu at `(x, y)` with no
scrim — a context menu / dropdown (the cursor position is the usual anchor). It has the same
press-outside-to-close (returns `false`) and background-inert behaviour as the modal, and is filled with
`menu_item(txt) -> bool` rows (full-width, accent-highlit on hover). Both overlays rest on `std/layout`'s
floating node — centred (`open_float`) or anchored (`open_float_at`), clamped on-screen.
Widgets: `button(txt) -> bool`, `primary(txt) -> bool`, `ghost_button(txt) -> bool` (a subtle, borderless
action — no fill at rest, a soft hover fill, muted ink; for toolbars + message Copy/Retry), `nav_item(txt, active) -> bool` (a
full-width **sidebar nav row** — GROWS to fill the panel width so it tracks a resizable sidebar, LEFT-aligned text that
**ellipsizes to its pixel width** (`text-overflow: ellipsis`, 1-frame lag like `text_area`), the accent fill when `active`;
ALWAYS place it in a `row` (its `grow` fills WIDTH there; bare in a column it would grow DOWN), optionally with a trailing
`ghost_button("···")` for per-item actions), `segmented(key, options, selected) -> int` (a
single-choice control — the selected option filled with the accent, the rest plain; returns the chosen
index, so it reads `idx = f.segmented(...)`), `avatar(glyph)` (a small rounded accent badge with a centred
glyph — a chat / identity mark), `label(s)`, `text_muted(s)`, `heading(s)`, `divider()` (a
full-width hairline section rule), `paragraph(text, width)` (word-WRAPPED *plain* prose),
`rich_text(text, width)` (word-wrapped prose with **inline** Markdown emphasis — `**bold**` as faux-bold,
`*italic*` in the italic face, `` `code` `` on a monospace chip, `[links](url)` in the accent with an
underline), `markdown(text, width)` (the full rich-text widget — parses `std/markdown` into the `Block`
enum and renders each via `match`: prose + bullets via `rich_text`, **size-stepped headings**, blockquotes
with an accent bar, **pipe tables** as an aligned grid (content-sized columns, faux-bold header + rule), and
code blocks in a monospace panel syntax-highlighted by `std/highlight` — whose text is **selectable**: drag to
select, Shift to extend, Ctrl/Cmd+A selects the block, Ctrl/Cmd+C copies, alongside the per-block Copy button
(read-only, reusing the field caret/selection/clipboard machinery; selection is per-block for now)),
`text_field(key, value) -> string` + `submit() -> bool` (Enter committed, clears the field),
`text_area(key, value) -> string` (a MULTI-LINE field that auto-grows to its content then scrolls — wrapped
visual lines, a 2D caret with ↑/↓ navigation, full selection/clipboard; **Shift+Enter inserts a newline**,
plain Enter is reported via `submit()` — the composer convention),
`splitter(key, size, lo, hi, vertical) -> int` (a draggable resize handle placed BETWEEN two panes: it
returns the maybe-updated size of the pane declared just before it, so you store the result and feed it back
— the `value = f.widget(key, value)` idiom. `vertical: true` = a vertical bar in a `row` resizing the WIDTH
of the pane to its left (the sidebar); `false` = a horizontal bar in a `column` resizing the HEIGHT of the pane
above it. Clamped to `[lo, hi]`; the OS cursor becomes a ↔/↕ resize arrow on hover. `flare.HANDLE_W` is the
handle's on-screen thickness, public so you can subtract it when sizing the remaining content).
(`checkbox`/`slider` exist in `std/ui` but aren't wrapped into the Flare layout model yet.)
Helper: `spinner(tick) -> string` returns the current frame of a `- \ | /` throbber for a frame counter —
a tiny loading indicator, e.g. `f.text_muted("Thinking " + flare.spinner(tick))`.

Everything delegates to `std/ui`, so the theme, the UI tape, and contracts carry over unchanged.

## Animation — springs + FLIP

Animation rides the **same keyed-state surface** as everything else, and steps over a **fixed per-frame
timestep** (`flare.SPRING_DT`) — so it is a *pure function of frame count*: deterministic, replayable, and
golden-testable, never coupled to the wall clock.

- **`spring(key, target) -> float`** eases a named value toward `target`, advancing it one fixed step this
  frame; its `(position, velocity)` live in a float-state column. It **snaps to target the first frame** a
  key is seen (no animate-in from zero), **retargets for free** (change the target any frame and the motion
  redirects smoothly with velocity intact — exactly what an immediate-mode UI needs as the user keeps
  interacting), and **settles** at a rest threshold so a finished spring stops churning state.
  `spring_with(key, target, stiffness, damping)` tunes the feel (damping below `2·√stiffness` overshoots).
  Drive a size, a scale, an offset:
  ```ember
  let w = f.spring("panel_w", if expanded 460.0 else 160.0)   // a panel width that eases between sizes
  f.panel_begin(START, CENTER); f.strut(to_int(w), 56); …; f.end()
  ```
- **`at(dx, dy) { … } end_at()`** shifts the **paint** of everything inside it by `(dx, dy)` pixels WITHOUT
  moving it in the layout solve — so a subtree slides *over* its neighbours. Feed it a spring for a drawer /
  sheet / toast. It's a pure paint-queue bracket (no layout node); brackets nest.
  ```ember
  let x = f.spring("drawer", if open 0.0 else 0.0 - 300.0)
  f.at(x, 0.0); f.panel_begin(…); …; f.end(); f.end_at()
  ```
- **`animate_layout(key) { … } end_animate_layout()`** AUTO-animates a subtree that **moved because the
  layout changed** — a sibling appeared, a list reordered, a panel resized (the **FLIP** technique). Flare
  gets it nearly for free: it re-solves real flexbox every frame *and* already caches every widget's
  last-frame rect, so last frame's solved position is the "First" measurement and this frame's solve is the
  "Last" — the spring just rides the difference, at paint time, never perturbing the solve. Give each item a
  **stable key** so the animation follows the item, not the slot:
  ```ember
  for id in order { f.animate_layout("row:" + id); f.row(…); …; f.end(); f.end_animate_layout() }
  ```

Runnable showcase: [`examples/graphics/18_flare_anim.em`](../examples/graphics/18_flare_anim.em) (a spring-driven
width + a FLIP add/remove list). Goldens: `tests/graphics/flare_spring.em`, `tests/graphics/flare_flip.em`.

## Notes & limits

- List state can be held however reads cleanest: an **array of structs** (`todos: [Todo]`, with
  `todos[i].done = …` — OFI-061, closed), a **`Map<string, T>`** of struct records (OFI-062/063,
  closed 2026-06-18 — value-structs now deep-clone through erased generics), or **parallel arrays**
  of Copy columns (`texts: [string]`, `dones: [bool]`). Flare's own last-frame hit-test cache uses a
  `Map<string, Rect>` now that the struct-valued-Map double-free is gone.
- Layout is a real flexbox now (`std/layout`): `row`/`column` with `justify`/`align`, `*_grow` to fill,
  `spacer`/`strut`, painted `panel_begin`, a scrollable `scroll_begin`/`scroll_end`, and a **floating
  node** (`open_float`, the basis for `modal_begin`/`modal_end`: declared anywhere, solved centred on the
  window). The full Claude-desktop app (`public/claude-desktop/flare_chat.em`) is built on it: fixed
  sidebar | growing main | bottom-pinned composer, full-width cards, a wrapped + scrollable transcript,
  rich markdown, the live STREAMING API, and a **settings dialog** (a `modal` of `segmented` controls).
  Remaining: a max transcript column width.
- `text_field` is a full single-line editor: caret, **horizontal scroll** (the text shifts so the
  caret stays inside a narrow field — OFI-055), **selection** (shift+arrows, shift+click, drag, and
  ⌘/Ctrl+A), and **clipboard** (⌘/Ctrl+C / X / V via the `clipboard_get`/`clipboard_set` natives).
  Typing, Backspace, or Delete over a selection replaces it. All of this is plain `std/ui` Ember over
  the existing code-point string ops (`str.cp_*`) and `key_down`/`char_pressed` — no new runtime hooks.
  Editing is code-point–correct: multi-byte UTF-8 (e.g. `é`) is one caret step, not one byte.


## Docking — retained layouts with `DockTree`

A **`DockTree`** is an app-owned, retained dock layout: a binary tree of split containers and panel
leaves, held across frames and mutated on interaction. It is **pure data** (no rendering, no Flare
state), stored as a parallel-array slotmap, so it is headless-testable and serialises cleanly.

```ember
var t = flare.dock_new()
let editor   = t.add_root("editor")                     // the first panel
let sidebar  = t.split(editor, "sidebar", true, 0.74)   // editor | sidebar  (vertical divider)
let terminal = t.split(editor, "terminal", false, 0.72) // editor / terminal (stacked)
```

- `add_root(panel)` seeds an empty tree with its first panel; returns the leaf index.
- `split(leaf, panel, vertical, ratio)` docks `panel` next to an existing `leaf`. A new split node
  takes the leaf's place, with the old leaf as child A and the new panel as child B; `vertical`
  picks a side-by-side vs stacked divider and `ratio` is child A's fraction. Returns the new leaf.
- `close(leaf)` removes a panel and **collapses its parent split** (the sibling takes the split's
  place), returning the removed panel id — pass it to **`f.forget(id)`** to dispose that panel's
  keyed state, so a closed panel leaks nothing (structure and state both reclaimed).
- `solve(x, y, w, h)` assigns every node an absolute rect (a split divides its rect by `ratio` with
  an 8px gap; a leaf takes its rect whole). Pure geometry — deterministic and headless-testable.

Render the whole tree with one call:

```ember
f.dock(t, 20, 20, screen_width() - 40, screen_height() - 40)
```

`f.dock` solves the tree and paints each panel as a themed frame (soft shadow, rounded fill,
hairline border, a title bar). It is **FLIP-animated**: each panel's drawn rect *springs* toward its
solved target (the same deterministic, fixed-timestep springs as the rest of Flare), so docking,
closing, or resizing a panel makes the others slide to fill the space instead of snapping. The
animation state is keyed under each panel's scope, so `f.forget(id)` disposes it along with the
panel's state. See `examples/graphics/19_dock.em` (press C to close a panel and watch the FLIP).

**Limits (current).** Panel *body* content is a placeholder — drawing real per-panel widgets,
divider drag-to-resize, drag-to-dock with drop zones, tab groups, and floating windows are the next
rung (the docking UX). The tree models tiled docking today.
