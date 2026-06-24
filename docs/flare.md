---
title: Flare — declarative UI
nav_order: 4
description: Flare is Ember's React-style declarative UI layer over immediate-mode widgets — components as functions, props, and local state, with no virtual DOM.
---

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

## Mental model

Three rules, and the rest follows:

1. **Your component function runs every frame** — ~60×/second — not once per "render". There is no reconciler
   deciding when to re-run it; the `loop` re-runs *everything*, unconditionally. So building the UI, handling
   an event, and reading state all happen in one straight-line pass you can read top to bottom.
2. **Events are return values, handled inline.** `if f.button("Save") { … }` *is* the click handler — it runs
   the instant the button reports a click, right where it sits. No callbacks, no effect queue, no re-render
   batching.
3. **State lives outside the function, in plain `var`s the loop owns.** You read them at the top of the frame
   and write them back as things change. This is why you almost never need a `useState` equivalent: a
   re-running function in React has nowhere stable to keep state, so React invented hooks; in Ember the loop
   *is* that stable place. `state_*` is only for state you want **encapsulated inside a reusable component**,
   so a caller needn't thread it.

Props are ordinary **typed function arguments**, so passing the wrong thing to a component is a *compile*
error, not a runtime surprise — the type system comes for free, with no `PropTypes` ceremony. There is no
virtual tree, no async re-render, no dependency arrays: **the frame is the unit**. If you can read the loop
body top to bottom, you understand the whole program.

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

## A bigger example — a settings dialog

The honest answer to "how does an immediate-mode UI hold a *tree* of mutable state?" is that it doesn't need
hooks or reducers — the tree is just plain `var`s the loop owns, mutated directly. Here a `modal` (a centred
panel over a dimmed scrim) of `segmented` controls drives appearance, model, and token settings; a `dirty`
flag is the app's own "unsaved" signal. Full runnable file:
[`examples/graphics/20_settings.em`](../examples/graphics/20_settings.em); the core:

```rust
var dark = false        // the whole "state tree" is just plain vars the loop owns
var open = true
var dirty = false

loop {
    // …draw the frame…
    if open {
        if !f.modal_begin("settings", 460, 0) {    // a scrim press closes it
            open = false
        }
        f.heading("Settings")

        f.text_muted("Appearance")
        var appear = 1
        if dark {
            appear = 0
        }
        let na = f.segmented("appearance", ["Dark", "Light"], appear)
        if na != appear {                          // a choice changed → mutate the var directly
            dark = (na == 0)
            if dark {
                f.use_dark()
            } else {
                f.use_light()
            }
            dirty = true
        }
        // …Model and Max-tokens follow the same shape: a segmented + an `if changed { … }`…

        if f.primary("Done") {
            open = false
        }
        f.modal_end()
    }
}
```

No `useState`, no reducer, no context provider — the dialog reads and writes ordinary variables, and it
scales to nested structs and arrays the same way. That is the composability story: there is no separate state
graph to keep consistent, because the state *is* your data.

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
Widgets: `button(txt) -> bool` (secondary), `primary(txt) -> bool` (the headline action, clay accent),
`danger(txt) -> bool` (a **destructive** action — the theme's red fill, for Delete/Remove/Discard; same shape
as `primary`, so the colour is the only signal — reach for it only when the action is hard to undo),
`ghost_button(txt) -> bool` (a subtle, borderless
action — no fill at rest, a soft hover fill, muted ink; for toolbars + message Copy/Retry), `nav_item(txt, active) -> bool` (a
full-width **sidebar nav row** — GROWS to fill the panel width so it tracks a resizable sidebar, LEFT-aligned text that
**ellipsizes to its pixel width** (`text-overflow: ellipsis`), **FLAT at rest** (no card — just text, like a VS Code /
Linear sidebar) with a fill only on hover and the accent fill when `active`;
ALWAYS place it in a `row` (its `grow` fills WIDTH there; bare in a column it would grow DOWN), optionally with a trailing
`ghost_button("···")` for per-item actions), `segmented(key, options, selected) -> int` (a
single-choice control — the selected option filled with the accent, the rest plain; returns the chosen
index, so it reads `idx = f.segmented(...)`), `avatar(glyph)` (a small rounded accent badge with a centred
glyph — a chat / identity mark), `label(s)`, `text_muted(s)`, `heading(s)` (single-line text — each
**ellipsizes** to its solved box width when too long (`text-overflow: ellipsis`), never spilling off-screen),
`divider()` (a
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

## Theming — one token set, two polarities

A theme is a plain `ui.Style` value: a palette plus a few metrics. Flare ships two house themes —
`use_light()` (warm "parchment + clay", the default) and `use_dark()` — built from the **same token set**,
so the only difference between them is the values, never the structure. Every widget reads from `f.ui.style`,
so theming is just data: swap the whole `Style` or tweak a field.

The tokens, grouped:

- **Surfaces** — `bg` (window), `panel` (card/widget fill), `bar` (a subtle elevated surface, e.g. a dock
  panel's title bar), `hover` / `pressed` (interaction fills), `track` (slider/scrollbar groove).
  `bar` is set **per theme** rather than derived by shading `panel`, because a fixed shade direction can't
  read on both grounds (a lighter step vanishes on a white panel) — the light/dark parity fix.
- **Ink** — `ink` (primary text), `muted_ink` (secondary/hints).
- **Accent & semantic** — `accent` / `accent_ink` (the headline action, selection, focus); `danger` /
  `danger_ink` (the destructive action — `f.danger()`).
- **Border & elevation** — `border` (hairline), `shadow` (drop-shadow alpha; 0 disables elevation).
- **Metrics** — `radius` (corner radius), `pad` (inter-widget gap + inner padding), `gutter` (the page-edge
  inset for top-level content — the outer margin, larger than `pad`, so a bare layout never kisses the window
  edge), `text_size`, `row_h`. The type metrics scale together under `set_zoom(pct)`.

Because a theme is just a `Style` value — a struct of packed colours and a few ints — an app owns it **as
data**: build one field by field, copy a house theme and tweak a field, or read one from a file and assign it
to `f.ui.style`. There is no theme *engine* to register with; swapping the struct re-skins every widget on the
next frame.

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
- `split(leaf, panel, vertical, ratio)` docks `panel` after an existing `leaf` — a new split node
  takes the leaf's place, the old leaf as child A and the new panel as child B (right / bottom);
  `vertical` picks a side-by-side vs stacked divider, `ratio` is child A's fraction. Returns the new
  leaf. **`split_before`** is its mirror — the new panel becomes child A (left / top), e.g. to
  re-dock a sidebar back on the left.
- `close(leaf)` removes a whole leaf and **collapses its parent split** (the sibling takes the split's
  place), returning the removed panel id — pass it to **`f.forget(id)`** to dispose that panel's
  keyed state, so a closed panel leaks nothing (structure and state both reclaimed).
- `leaf_of(panel)` resolves a panel id to its leaf index (or `-1`), finding the panel in **any of a
  leaf's tabs** — the lookup an app uses to re-dock beside a known panel, or to test whether one is open.
- `redock(panel, target, side)` moves an already-docked `panel` relative to `target`: `side` 0 left /
  1 right / 2 top / 3 bottom splits beside it, **`side` 4 (centre) groups `panel` into `target`'s leaf
  as a tab**. It *detaches* the panel first (dropping just that tab if it shared a group, else collapsing
  its leaf) and resolves `target` by id *after*, so a slot reshuffle can't stale it. The panel keeps its
  id (and state). The tree op behind drag-to-redock; a no-op (`false`) on a self-drop or unknown
  panel/target.
- `dock_root_edge(panel, side)` docks `panel` against an **outer edge of the whole workspace** —
  it detaches the panel, then wraps the entire root (leaf or split) in a fresh split with `panel` on
  `side`. The drag op for the workspace-edge bands.
- `solve(x, y, w, h)` assigns every node an absolute rect (a split divides its rect by `ratio` with
  an 8px gap; a leaf takes its rect whole). Pure geometry — deterministic and headless-testable.

**Tabs.** A leaf is a *tab group* of one or more panels (a single panel is just a one-tab leaf, so
non-tabbed docking is unchanged). `tabs_of(leaf)` returns the tab ids, `tab_count(leaf)` how many,
`active_tab(leaf)` the visible one's index; `set_active(leaf, idx)` switches it, `add_tab(leaf, panel)`
groups a panel in (the panel must already be detached — `redock(_, _, 4)` does both). `close_tab(leaf)`
closes the **active** tab (the leaf survives with the rest, or collapses if it was the last) and returns
the removed id — this is what a panel's ✕ triggers, so wire `dock_begin`'s returned leaf to
`t.close_tab(hit)` and `f.forget()` the result. `leaves()` returns the **active** panel of each leaf, so
an app's render loop is unchanged — it draws the active tab of every leaf.

A module-level **`dock_zone(x, y, w, h, mx, my) -> int`** classifies where a cursor falls in a rect
for drop targeting (`-1` outside, `0`–`3` the nearest edge, `4` the centre box → tabify) — pure
geometry, so the drop preview and the mutation it triggers share one source of truth.

**Persistence.** `t.to_json()` serialises the whole tree to a `std/json` value (every node's
kind/parent/children/divider/ratio + each leaf's tabs/active + the root), and **`dock_from_json(j)`**
rebuilds it — so a rearranged workspace **survives relaunch**. Stash it next to your other settings
(`json.member("dock", t.to_json())`), and on load rebuild with `dock_from_json`, validating it first —
e.g. `if t2.leaf_of("Main") >= 0 { … } else { build_default() }` — so a stale or corrupt layout falls
back to the default instead of opening empty. Solved rects and the `dk_panel` mirror aren't stored
(transient / derived); ratios round-trip as integers (`int(r·1000)`), so the layout is exact.

### Rendering & interaction

Render the workspace in three parts: open it, fill each panel, done.

```ember
f.dock_pin("Chat")                                            // (optional) a permanent anchor — no close ✕
let hit = f.dock_begin(t, 12, 12, screen_width() - 24, screen_height() - 24)
if hit >= 0 { let id = t.close_tab(hit); f.forget(id) }       // a ✕ was clicked → close active tab + dispose

let ids = t.leaves()
var i = 0
loop {
    if i == ids.len() { break }
    if f.dock_panel(ids[i]) {                                 // open a clipped, flexbox content region
        // …ordinary Flare widgets: heading / paragraph / scroll / text_area / nav_item…
        f.dock_panel_end()
    }
    i = i + 1
}
```

- **`dock_begin(t, x, y, w, h) -> int`** solves the tree and paints every panel as a themed frame
  (soft shadow, rounded fill, hairline border, a title bar with a close ✕). It draws a **draggable
  divider** at each split — grab it and the panes re-proportion live (the `ratio` tracks the cursor,
  clamped to 8–92%). It also handles **drag-a-title-bar-to-redock** and renders a **tab strip** for any
  grouped leaf (click a tab to switch; below). It returns the **leaf index whose active-tab ✕ was
  clicked** this frame (or `-1`) — wire it to `t.close_tab(hit)`.
- **`dock_panel(id) -> bool`** opens a content region anchored at that panel's solved body rect
  (below the title bar) and **clipped to it** — a full floating flexbox subtree, so `column` / `row`
  / `grow` / `scroll_begin` / `text_area` all compose inside exactly as at the top level. Returns
  `false` (build nothing) if `id` isn't a live panel this frame. Pair every `true` with
  `dock_panel_end()`.
- **`dock_pin(id)`** (call before `dock_begin`, each frame) marks a panel as non-closable — it draws
  no ✕. For an app's main view that should always stay docked.

**Drag a title bar to re-dock.** Grab any panel's title bar (or one of its tabs) and drag it — past a
small threshold a **ghost chip** follows the cursor and a translucent **drop preview** lights up where it
will land. Hover the **left / right / top / bottom third** of another panel to dock beside it, the
**centre** to group it as a **tab**, or the **outer edge band** of the whole workspace to dock against the
full side. Release to re-dock; the tree mutates and the other panels FLIP-slide to make room. A panel
keeps its id across the move, so its state (scroll position, drafts) survives. A bare click — no drag past
the threshold — does nothing, so title bars and tabs stay clickable. Pinned panels (no ✕) are still
draggable; pinning only removes *closing*, not *moving*. The interaction is entirely inside `dock_begin` —
an app that already renders a dock gets it for free. (The redock itself is the pure tree op
`t.redock(panel, target, side)` / `t.dock_root_edge(panel, side)`, and `dock_zone(...)` is the headless
drop-zone geometry, if an app wants to drive docking programmatically.)

**Tabs.** Drop a panel on another's centre and the two share a leaf as **tabs** — a chip strip in the
title bar, the active one raised with an accent underline. Click a chip to switch (it activates on the
press, so the same gesture can drag that tab straight back out to its own pane); the ✕ closes the active
tab, collapsing the leaf only when its last tab goes. `dock_panel` renders only the active tab of each
leaf, so a tab group costs nothing extra to drive.

It is **FLIP-animated**: each panel's drawn rect *springs* toward its solved target (the same
deterministic, fixed-timestep springs as the rest of Flare), so docking and closing a panel makes
the others *slide* to fill the space. During an active divider drag the panes **snap** instead, so a
resize feels direct rather than rubber-banding behind the cursor. The animation state is keyed under
each panel's id, so `f.forget(id)` disposes it along with the panel's state.

See **`examples/graphics/19_dock.em`** for a live interactive workspace (drag a title bar to re-dock or
group as tabs, drag the dividers, click ✕, `R` resets), and **`public/claude-desktop/flare_chat.em`** — the
Claude app's whole body is a dock: Conversations | Chat | Inspector, with Chat pinned and the side panels
closeable, re-dockable, **tabbable**, and freely **rearrangeable by dragging their title bars**.

**Limits (current).** **Floating windows** (pop a panel out into its own free-floating, draggable window)
are the next rung; tiled docking with live resize, drag-to-redock, and tab groups is the model today. The
layout now **persists** across relaunch (`to_json` / `dock_from_json`, see *Persistence* above — OFI-112
closed); `flare_chat` saves it in its store, so a resized/closed/re-docked/tabbed workspace comes back.
