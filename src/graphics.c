#include "graphics.h"

// raylib is included ONLY here, behind EMBER_GRAPHICS, so the rest of the compiler
// never sees its headers and the default build needs no display or dependency. In a
// non-graphics build this is an (almost) empty translation unit.
typedef int ember_gfx_unit_placeholder;   // keeps the TU non-empty when graphics off

#if EMBER_GRAPHICS
#include "raylib.h"
#include "rlgl.h"         // rlDrawRenderBatchActive — flush the batch before a screenshot
#include "font_inter.h"   // embedded Inter Regular (TrueType) — see header
#include <ft2build.h>     // FreeType: hinted, high-quality glyph rasterisation (opt-in graphics dep)
#include FT_FREETYPE_H
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <math.h>

// ---- Text rendering: FreeType, rasterised at the real device pixel size ------------
// raylib's own font path uses stb_truetype and bakes ONE atlas at a base size that is then
// scaled in DrawTextEx — which discards hinting the moment the drawn size differs from the bake
// size, leaving small UI text soft on a fixed-resolution (1x) display. We instead rasterise each
// glyph with FreeType (light hinting, so stems snap to the pixel grid) AT the exact physical pixel
// size it will occupy, and cache one raylib Font per (slot, physical-pixel-size). Because the Font
// is baked at the physical size and drawn 1:1 under the HiDPI camera, the hinting survives all the
// way to the screen on every display. All text still funnels through draw_text / measure_text, so
// the whole toolkit gets crisp text for free.
#define GFX_FONT_MAX 8           // distinct typefaces (faces) the registry can hold
#define GFX_SIZE_CACHE_MAX 24    // distinct physical pixel sizes cached per face
#define GFX_SEED_FIRST 32        // each size atlas is SEEDED with printable ASCII 32..126 so the
#define GFX_SEED_LAST 126        // common path never rebuilds; any other code point is rasterised
                                 // on demand and the atlas grows (OFI-069). The face's glyph set is
                                 // the only ceiling — a code point it lacks still falls back to '?'.

// One on-demand-grown raylib Font, the cache value keyed by px. `cps` is the SORTED set of code
// points currently baked into this atlas; gfx_size_ensure() adds any missing ones (decoded from the
// text about to be drawn/measured) and rebuilds the atlas, so glyphs appear lazily on first use.
typedef struct {
    int  px;          // physical pixel size this Font was rasterised at (the cache key)
    Font font;        // raylib Font built from FreeType-rendered glyphs at `px`
    int  valid;       // 0 until built (a face with no glyphs at this size stays invalid)
    int *cps;         // code points in the atlas, ascending (owned; freed at window close)
    int  cp_count;
    int  cp_cap;
} GfxSizedFont;


// One typeface slot: the FreeType face plus its per-size cache of baked raylib Fonts.
typedef struct {
    FT_Face      face;                          // owns the rasteriser for this typeface
    int          loaded;                        // 1 once `face` is live
    GfxSizedFont sizes[GFX_SIZE_CACHE_MAX];     // baked Fonts, one per physical pixel size seen
    int          size_count;
} GfxFont;

// Font registry: slot 0 is the embedded Inter (always loaded); load_font() appends more from disk
// (a system or downloaded TTF/OTF) and returns its slot id. set_font() picks the slot for the text
// that follows; each text command captures the slot so the deferred flush draws in the right face.
static FT_Library g_ft;             // the FreeType library handle (one per process)
static int        g_ft_ready = 0;   // 1 once FT_Init_FreeType succeeded
static GfxFont    g_fonts[GFX_FONT_MAX];
static int        g_font_count = 0;       // number of loaded faces (>=1 once the window is open)
static int        g_cur_font   = 0;       // active font slot for draw_text / measure_text
static int        g_alpha      = 255;     // active fade multiplier (0..255): every command records it, folded at flush

// HiDPI/Retina backing-scale factor (OFI-060). On a 1x display this is 1.0 and the whole
// scaling path below is a mathematical identity, so 1x output is byte-for-byte unchanged.
// On a 2x Retina panel it is 2.0: the framebuffer is physical-resolution (FLAG_WINDOW_HIGHDPI)
// and the frame renders under a Camera2D whose zoom == g_scale, so the entire toolkit keeps
// describing the UI in LOGICAL points while the GPU maps them to physical pixels. raylib already
// DPI-scales scissor (BeginScissorMode), mouse, and GetScreenWidth/Height on Apple, so those
// stay logical and consistent with the camera — no per-call scaling anywhere else.
static float g_scale = 1.0f;


// gfx_backing_scale — the camera zoom that maps our logical-point coordinates onto the real
// framebuffer. This is the ACTUAL framebuffer-to-window ratio (render px / screen pt), NOT
// GetWindowScaleDPI(): that returns the *monitor's* DPI scale, which on macOS can read 2.0 even
// when the window's backing store is only 1x (a non-bundled binary that didn't get a Retina
// surface, or a scaled display mode). Trusting the monitor scale there zooms 2x into a 1x buffer
// and the whole UI renders double-size (OFI-060 follow-up). Deriving the scale from the buffers
// we actually have is correct in every configuration: full-Retina → 2.0, 1x → 1.0, anything between.
static float gfx_backing_scale(void) {
    int sw = GetScreenWidth();
    int rw = GetRenderWidth();
    if (sw <= 0 || rw <= 0) {
        return 1.0f;            // before the window settles; corrected on the next frame
    }
    float s = (float)rw / (float)sw;
    return (s < 1.0f) ? 1.0f : s;
}


// Extra inter-glyph spacing, kept in ONE place so draw and measure always agree (any
// mismatch would make widget auto-sizing wrong). Scales with the text size.
static float gfx_text_spacing(int size) {
    return (float)size / 16.0f;
}




// ---- measure_text cache ---------------------------------------------------------------------------
// Text metrics are a pure function of (string, font slot, logical size, backing scale): MeasureTextEx
// walks every glyph, yet an immediate-mode UI measures the SAME strings every frame — label widths, the
// word-wrapper's growing trial line, ellipsis fitting — usually twice (layout then paint). This direct-
// mapped cache memoises the width so a warm frame does almost no FreeType measuring. Eviction-on-collision
// bounds memory to the table; a backing-scale change (the window moved to a different-DPI display) flushes
// it, since the glyph metrics shift with the physical pixel size.
#define MEASURE_CACHE_BITS 14
#define MEASURE_CACHE_SIZE (1 << MEASURE_CACHE_BITS)   // 16384 slots, direct-mapped
typedef struct {
    uint64_t hash;     // 0 = empty slot
    char    *text;     // owned copy of the measured string (NULL when empty)
    int      font;
    int      size;
    int      width;
} MeasureEntry;
static MeasureEntry g_measure_cache[MEASURE_CACHE_SIZE];
static float        g_measure_cache_scale = 0.0f;      // backing scale the cached widths were measured at
static long         g_measure_calls = 0;               // measure_text() calls this frame (perf instrument)
static long         g_measure_ft    = 0;               // of those, actual MeasureTextEx invocations (misses)
static int          g_measure_stats = 0;               // EMBER_MEASURE_STATS → log per-frame work + measures
static double       g_work_t0       = 0.0;             // GetTime() when this frame's CPU work began (frame_begin)
static double       g_work_ms       = 0.0;             // last frame's CPU work (build+layout+paint), excl. the wait

static uint64_t gfx_measure_hash(const char *text, int font, int size) {
    uint64_t h = 1469598103934665603ULL;               // FNV-1a over the bytes, then fold in font + size
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        h ^= *p;
        h *= 1099511628211ULL;
    }
    h ^= (uint64_t)font;
    h *= 1099511628211ULL;
    h ^= (uint64_t)size;
    h *= 1099511628211ULL;
    return h;
}

static void gfx_measure_cache_flush(void) {
    for (int i = 0; i < MEASURE_CACHE_SIZE; i++) {
        free(g_measure_cache[i].text);
        g_measure_cache[i].text = NULL;
        g_measure_cache[i].hash = 0;
    }
}

// measure_misses exposes this frame's cache-miss count (real FreeType measures) so a program — or a
// regression test — can verify the cache is actually warming: a second identical frame should miss zero.
int ember_gfx_measure_misses(void) {
    return (int)g_measure_ft;
}




// frame_steps returns how many FIXED 1/60s physics steps the LAST frame's wall-time spanned — the
// number of times a spring/FLIP integrator should advance this frame so the animation runs in real time
// regardless of frame rate. At a steady 60fps (including the SetTargetFPS-paced golden runs) it is 1, so
// the fixed-timestep physics stays byte-for-byte deterministic; when frames are heavy (a busy redock drops
// to, say, 20fps) it returns 3, so the spring catches up instead of playing in slow motion. Capped so a
// long stall (window backgrounded) can't teleport the spring across the screen in one jump.
int ember_gfx_frame_steps(void) {
    long n = lroundf(GetFrameTime() * 60.0f);   // GetFrameTime() = seconds since last EndDrawing (0 first frame)
    if (n < 1) {
        n = 1;                                  // always advance at least one step (first/paced frame → 1)
    }
    if (n > 10) {
        n = 10;                                 // cap catch-up (≈6fps floor) so a stall can't jump the spring
    }
    return (int)n;
}




// set_alpha sets the active fade multiplier (0..255) that every following draw command captures and folds
// into its final opacity at flush. The Flare paint loop drives it from a _FADE bracket (nesting multiplies),
// and frame_begin resets it to 255. This is how a whole subtree fades in/out as one (presence, dimming).
void ember_gfx_set_alpha(int a) {
    if (a < 0) {
        a = 0;
    }
    if (a > 255) {
        a = 255;
    }
    g_alpha = a;
}

// Unpack a 0xRRGGBB color int into a raylib Color (always opaque).
static Color gfx_color(int packed) {
    Color c;
    c.r = (unsigned char)((packed >> 16) & 0xFF);
    c.g = (unsigned char)((packed >> 8) & 0xFF);
    c.b = (unsigned char)(packed & 0xFF);
    c.a = 255;
    return c;
}


// Same, but with an explicit 0..255 alpha — the basis of translucent fills, borders, gradients,
// and soft shadows (the modern look layers many partly-transparent shapes).
static Color gfx_rgba(int packed, int alpha) {
    Color c = gfx_color(packed);
    c.a = (unsigned char)(alpha < 0 ? 0 : alpha > 255 ? 255 : alpha);
    return c;
}


// raylib's DrawRectangleRounded takes "roundness" in 0..1 (fraction of the short side); convert a
// pixel corner radius to that, clamped so a large radius just yields a pill/half-circle end.
static float gfx_roundness(int radius, int w, int h) {
    int shortside = w < h ? w : h;
    if (shortside <= 0 || radius <= 0) {
        return 0.0f;
    }
    float r = (float)radius / ((float)shortside * 0.5f);
    return r > 1.0f ? 1.0f : r;
}






// ---- Deferred draw command buffer (MANIFESTO §5g, Phase B) ------------------------
// draw_rect/draw_text no longer render on the spot — they APPEND a command tagged with
// the current layer. frame_end stable-sorts by layer (low→high, ties keep append order)
// and renders, so a window on a higher layer overlaps one below it regardless of the
// order their widgets were described in. With everything on layer 0 (the default) the
// sort is a no-op and the result is identical to immediate drawing. set_layer picks the
// layer for the commands that follow.
//
// CLIP_PUSH/CLIP_POP bracket a clip region (raylib scissor): draw commands rendered
// between them are masked to the rectangle, so a window's content can't bleed past its
// frame onto a neighbour. They nest by INTERSECTION (a clip inside a clip is the overlap)
// so a scroll region inside a window works. Because every window's commands share one
// layer and stay contiguous after the stable sort, a push/pop pair stays paired and in
// order through the sort.
typedef enum {
    GCMD_RECT, GCMD_TEXT, GCMD_CLIP_PUSH, GCMD_CLIP_POP,
    GCMD_ROUND, GCMD_STROKE, GCMD_GRAD, GCMD_SHADOW, GCMD_CIRCLE
} GfxCmdKind;


typedef struct {
    GfxCmdKind kind;
    int        layer;       // z: lower draws first (behind)
    int        seq;         // append order — the stable-sort tiebreak within a layer
    int        x, y, w, h;  // rect/clip/round/grad/shadow use all four; circle uses x,y=centre,w=r
    int        size;        // text point size
    int        color;       // packed 0xRRGGBB (gradient top / circle / stroke / fill)
    int        color2;      // gradient bottom
    int        radius;      // corner radius (px) for round/stroke/grad/shadow
    int        alpha;       // 0..255 final opacity (after the fade multiplier is folded in at flush)
    int        fade;        // 0..255 fade multiplier captured at record time (g_alpha); folded into alpha post-sort
    int        thick;       // stroke line thickness
    int        font;        // font slot for text commands (captured from g_cur_font)
    char      *text;        // strdup'd for text commands, NULL otherwise; freed on flush
} GfxCmd;


static GfxCmd *g_cmds      = NULL;
static int     g_cmd_count = 0;
static int     g_cmd_cap   = 0;
static int     g_cur_layer = 0;


// Render-time clip stack (used while flushing in frame_end). Each entry is the live
// scissor rectangle; a push intersects with the entry below it so clips nest.
#define GFX_CLIP_MAX 16
static int g_clip[GFX_CLIP_MAX][4];   // x, y, w, h
static int g_clip_depth = 0;


// ---- UI tape (MANIFESTO §5c) -------------------------------------------------------
// A machine-readable record of what the UI did each frame: the input that drove it and
// every draw command issued — plus high-level interaction events (click/toggle/focus)
// that std/ui marks. It's the same JSON-lines shape as the instruction tape, so an LLM
// parses it the same way, but at frame granularity (the per-instruction tape is far too
// fine for a 60fps loop). Off unless tape_open() is called; then every frame_end appends
// a record. This is Ember's answer to "why did my UI do that?" as structured data.
static FILE *g_tape       = NULL;
static int   g_frame      = 0;     // frame counter since tape_open
static int   g_fmx, g_fmy, g_fdown;  // input snapshot captured at frame_begin

// A pending screenshot path, set by frame_capture() and honoured once at the next
// frame_end (after the draw loop, before the buffer swap). Empty = no capture queued.
// Capturing must be deferred this way because draws are batched into g_cmds and only
// reach the framebuffer during frame_end — a capture taken mid-frame would be blank.
static char  g_capture_path[1024] = "";

// EMBER_CAPTURE=path[@frame] auto-screenshots `frame` (default 20) to `path`, then closes the
// window — so any graphics program can be captured unmodified for baselines, docs, and visual
// goldens (the env-driven sibling of EMBER_TAPE). -1 = disabled.
static char  g_autocap_path[1024] = "";
static int   g_autocap_at   = -1;   // target frame to capture (-1 = disabled)
static int   g_autocap_seen = 0;    // frames presented so far this run
static int   g_force_close  = 0;    // 1 once the auto-capture frame has been taken


// Write a JSON string literal (minimal escaping) to the tape.
static void gfx_json_str(FILE *f, const char *s) {
    fputc('"', f);
    for (const char *p = s; *p != '\0'; p++) {
        if (*p == '"' || *p == '\\') {
            fputc('\\', f);
            fputc(*p, f);
        } else if (*p == '\n') {
            fputs("\\n", f);
        } else {
            fputc(*p, f);
        }
    }
    fputc('"', f);
}


// Reserve and return the next command slot, growing the buffer geometrically.
static GfxCmd *gfx_push_cmd(void) {
    if (g_cmd_count == g_cmd_cap) {
        g_cmd_cap = g_cmd_cap ? g_cmd_cap * 2 : 128;
        g_cmds = realloc(g_cmds, (size_t)g_cmd_cap * sizeof(GfxCmd));
    }
    GfxCmd *c = &g_cmds[g_cmd_count];
    c->layer = g_cur_layer;
    c->seq   = g_cmd_count;
    c->text  = NULL;
    c->alpha = 255;          // opaque by default; the rich primitives override before flush
    c->fade  = g_alpha;      // capture the active fade multiplier; folded into alpha after the z-sort
    g_cmd_count++;
    return c;
}


// Order commands by layer, breaking ties by append order so each layer stays stable.
static int gfx_cmd_cmp(const void *a, const void *b) {
    const GfxCmd *ca = (const GfxCmd *)a;
    const GfxCmd *cb = (const GfxCmd *)b;
    if (ca->layer != cb->layer) {
        return ca->layer - cb->layer;
    }
    return ca->seq - cb->seq;
}






// Build a raylib Font for `face` rasterised at `px` physical pixels with FreeType, hinted so stems
// land on the pixel grid. Each code point in cps[0..count) is rendered to an 8-bit coverage bitmap
// and handed to raylib's atlas packer; the Font's images/recs are then owned by the Font and
// released by UnloadFont. Returns a Font with texture.id == 0 on failure (caller treats as invalid).
static Font gfx_build_font_px(FT_Face face, int px, const int *cps, int count) {
    Font font = { 0 };
    if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)px) != 0) {
        return font;
    }
    int ascender = (int)(face->size->metrics.ascender >> 6);   // px from the baseline up to line top
    GlyphInfo *glyphs = (GlyphInfo *)calloc((size_t)count, sizeof(GlyphInfo));
    if (glyphs == NULL) {
        return font;
    }
    for (int i = 0; i < count; i++) {
        int cp = cps[i];
        glyphs[i].value = cp;
        // FT_LOAD_TARGET_LIGHT — the autohinter's light mode: vertical grid-fitting only, no
        // horizontal hinting, so stems sharpen while advances stay smooth. The right target for UI.
        if (FT_Load_Char(face, (FT_ULong)cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT) != 0) {
            continue;   // leaves a zero-area glyph; raylib's packer skips it
        }
        FT_GlyphSlot g = face->glyph;
        glyphs[i].offsetX  = g->bitmap_left;
        glyphs[i].offsetY  = ascender - g->bitmap_top;   // glyph top, relative to the line top
        glyphs[i].advanceX = (int)(g->advance.x >> 6);
        int w = (int)g->bitmap.width, h = (int)g->bitmap.rows;
        int pitch = g->bitmap.pitch;
        if (w > 0 && h > 0 && pitch != 0) {
            unsigned char *buf = (unsigned char *)malloc((size_t)w * (size_t)h);
            if (buf == NULL) {
                continue;
            }
            for (int row = 0; row < h; row++) {   // copy honouring FreeType's row pitch
                memcpy(buf + (size_t)row * (size_t)w,
                       g->bitmap.buffer + (size_t)row * (size_t)pitch, (size_t)w);
            }
            glyphs[i].image.data    = buf;
            glyphs[i].image.width   = w;
            glyphs[i].image.height  = h;
            glyphs[i].image.mipmaps = 1;
            glyphs[i].image.format  = PIXELFORMAT_UNCOMPRESSED_GRAYSCALE;
        }
        // else: zero-area glyph (e.g. space) — advance only, no bitmap.
    }
    Rectangle *recs = NULL;
    Image atlas = GenImageFontAtlas(glyphs, &recs, count, px, 4 /*padding*/, 1 /*skyline pack*/);
    font.baseSize     = px;
    font.glyphCount   = count;
    font.glyphPadding = 4;
    font.glyphs       = glyphs;     // ownership → Font (UnloadFont frees glyphs + their images)
    font.recs         = recs;       // ownership → Font
    font.texture      = LoadTextureFromImage(atlas);
    UnloadImage(atlas);
    SetTextureFilter(font.texture, TEXTURE_FILTER_BILINEAR);
    return font;
}






// Membership test in the ascending cps set (binary search).
static int gfx_cp_has(const GfxSizedFont *e, int cp) {
    int lo = 0, hi = e->cp_count - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        if (e->cps[mid] == cp) {
            return 1;
        }
        if (e->cps[mid] < cp) {
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return 0;
}


// Insert cp into the ascending cps set (caller has checked it is absent). Grows the array; returns 0
// only on allocation failure.
static int gfx_cp_insert(GfxSizedFont *e, int cp) {
    if (e->cp_count >= e->cp_cap) {
        int ncap = (e->cp_cap < 128) ? 128 : e->cp_cap * 2;
        int *n = (int *)realloc(e->cps, (size_t)ncap * sizeof(int));
        if (n == NULL) {
            return 0;
        }
        e->cps = n;
        e->cp_cap = ncap;
    }
    int i = e->cp_count - 1;
    while (i >= 0 && e->cps[i] > cp) {       // shift up to keep the set sorted
        e->cps[i + 1] = e->cps[i];
        i--;
    }
    e->cps[i + 1] = cp;
    e->cp_count++;
    return 1;
}


// Ensure every code point in `text` is baked into entry `e`'s atlas, rebuilding it ONCE if any were
// missing (OFI-069). Once a UI's character set has been seen this is a pure membership scan — no work,
// no allocation, no GPU upload — so steady-state text drawing keeps the old fixed-atlas speed.
static void gfx_size_ensure(GfxSizedFont *e, FT_Face face, const char *text) {
    if (text == NULL || !e->valid) {
        return;
    }
    int added = 0;
    const char *p = text;
    while (*p != '\0') {
        int sz = 0;
        int cp = GetCodepointNext(p, &sz);   // raylib UTF-8 decode; invalid byte → '?' (0x3F)
        p += (sz > 0) ? sz : 1;
        if (cp <= 32 || cp == 0x3F) {        // ASCII control/space + '?' are already in the seed set
            continue;
        }
        // Only bake code points the FACE actually has. For one it lacks, FT_Load_Char would render
        // the .notdef "tofu" box; instead we leave it out of the atlas so raylib draws its '?'.
        if (!gfx_cp_has(e, cp) && FT_Get_Char_Index(face, (FT_ULong)cp) != 0 && gfx_cp_insert(e, cp)) {
            added = 1;
        }
    }
    if (added) {
        Font rebuilt = gfx_build_font_px(face, e->px, e->cps, e->cp_count);
        if (rebuilt.texture.id != 0) {
            UnloadFont(e->font);             // free the previous atlas texture + glyph images
            e->font = rebuilt;
        }
        // else: rebuild failed (OOM) — keep the working atlas; the new code point renders as '?'.
    }
}


// Get (or lazily create) the size-cache entry for an already-resolved face `gf` at physical size `px`,
// its atlas SEEDED with printable ASCII. Falls back to the nearest cached size when the per-face cache
// is full. Returns NULL only if the seed build fails.
static GfxSizedFont *gfx_size_entry(GfxFont *gf, int px) {
    if (px < 1) {
        px = 1;
    }
    for (int i = 0; i < gf->size_count; i++) {
        if (gf->sizes[i].px == px) {
            return gf->sizes[i].valid ? &gf->sizes[i] : NULL;
        }
    }
    if (gf->size_count >= GFX_SIZE_CACHE_MAX) {
        // Cache full (pathological — a UI using dozens of distinct sizes). Reuse the nearest cached
        // size rather than failing: slightly off but never blank text.
        int best = -1, bestd = 1 << 30;
        for (int i = 0; i < gf->size_count; i++) {
            int d = gf->sizes[i].px - px;
            d = d < 0 ? -d : d;
            if (gf->sizes[i].valid && d < bestd) {
                bestd = d;
                best = i;
            }
        }
        return best >= 0 ? &gf->sizes[best] : NULL;
    }
    GfxSizedFont *e = &gf->sizes[gf->size_count++];
    e->px = px;
    e->cps = NULL;
    e->cp_count = 0;
    e->cp_cap = 0;
    for (int cp = GFX_SEED_FIRST; cp <= GFX_SEED_LAST; cp++) {
        gfx_cp_insert(e, cp);                // ascending, so each is a cheap append
    }
    e->font = gfx_build_font_px(gf->face, e->px, e->cps, e->cp_count);
    e->valid = (e->font.texture.id != 0) ? 1 : 0;
    return e->valid ? e : NULL;
}


// Resolve the Font for (slot, px) and guarantee `text`'s code points are baked into it first. Falls
// back to slot 0 (the always-present embedded face) for an out-of-range/unloaded slot; returns NULL
// only if no usable face exists at all (FreeType failed to initialise).
static Font *gfx_font_for(int slot, int px, const char *text) {
    if (slot < 0 || slot >= g_font_count || !g_fonts[slot].loaded) {
        slot = 0;
    }
    if (g_font_count == 0 || !g_fonts[slot].loaded) {
        return NULL;
    }
    GfxFont *gf = &g_fonts[slot];
    GfxSizedFont *e = gfx_size_entry(gf, px);
    if (e == NULL) {
        return NULL;
    }
    gfx_size_ensure(e, gf->face, text);
    return e->valid ? &e->font : NULL;
}






void ember_gfx_window_open(int width, int height, const char *title) {
    SetTraceLogLevel(LOG_WARNING);   // hush raylib's INFO startup spam on stdout
    // FLAG_WINDOW_HIGHDPI (OFI-060): on a Retina panel this opens a physical-resolution
    // framebuffer so text is rasterised at true device pixels instead of being upscaled by
    // the OS. On a 1x display it is inert. MSAA_4X smooths vector edges (not text quads).
    SetConfigFlags(FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT | FLAG_WINDOW_HIGHDPI);
    InitWindow(width, height, title);
    g_scale = gfx_backing_scale();   // real framebuffer ratio, not the monitor DPI (see helper)
    g_measure_stats = (getenv("EMBER_MEASURE_STATS") != NULL) ? 1 : 0;   // per-frame text-measure profiling
    SetTargetFPS(60);
    // FreeType rasteriser for all text. Slot 0 is the embedded Inter, loaded from its static
    // memory — the bytes outlive the face, so FreeType references them directly with no copy.
    // Glyph atlases are baked lazily per physical pixel size on first use (gfx_font_for).
    if (!g_ft_ready) {
        g_ft_ready = (FT_Init_FreeType(&g_ft) == 0) ? 1 : 0;
    }
    memset(g_fonts, 0, sizeof(g_fonts));
    g_font_count = 0;
    if (g_ft_ready &&
        FT_New_Memory_Face(g_ft, Inter_Regular_ttf, (FT_Long)Inter_Regular_ttf_len, 0,
                           &g_fonts[0].face) == 0) {
        g_fonts[0].loaded = 1;
        g_font_count = 1;
    }
    g_cur_font = 0;

    // EMBER_CAPTURE=path[@frame] — auto-screenshot for baselines/docs/goldens (see statics).
    g_autocap_path[0] = '\0';
    g_autocap_at = -1;
    g_autocap_seen = 0;
    g_force_close = 0;
    const char *cap = getenv("EMBER_CAPTURE");
    if (cap != NULL && cap[0] != '\0') {
        const char *at = strrchr(cap, '@');
        int frame = 20;
        size_t plen = strlen(cap);
        if (at != NULL && at[1] != '\0') {   // a trailing @N selects the frame
            int f = 0, ok = 1;
            for (const char *p = at + 1; *p != '\0'; p++) {
                if (*p < '0' || *p > '9') { ok = 0; break; }
                f = f * 10 + (*p - '0');
            }
            if (ok) { frame = f; plen = (size_t)(at - cap); }
        }
        if (plen > 0 && plen < sizeof(g_autocap_path)) {
            memcpy(g_autocap_path, cap, plen);
            g_autocap_path[plen] = '\0';
            g_autocap_at = frame;
        }
    }
}






void ember_gfx_window_close(void) {
    if (g_tape != NULL) {       // flush + close the tape if the program left it open
        fclose(g_tape);
        g_tape = NULL;
    }
    gfx_measure_cache_flush();  // free the measure cache's owned string copies (clean teardown / ASan)
    for (int i = 0; i < g_font_count; i++) {
        for (int s = 0; s < g_fonts[i].size_count; s++) {
            if (g_fonts[i].sizes[s].valid) {
                UnloadFont(g_fonts[i].sizes[s].font);   // frees the size's atlas texture, glyphs, recs
            }
            free(g_fonts[i].sizes[s].cps);              // the on-demand code-point set (OFI-069)
        }
        if (g_fonts[i].loaded) {
            FT_Done_Face(g_fonts[i].face);
        }
    }
    memset(g_fonts, 0, sizeof(g_fonts));
    g_font_count = 0;
    g_cur_font = 0;
    CloseWindow();
    // g_ft (the FreeType library) is kept process-lifetime so a window can be reopened.
}






int ember_gfx_should_close(void) {
    if (g_force_close) {   // EMBER_CAPTURE has taken its shot; exit after this frame
        return 1;
    }
    return WindowShouldClose() ? 1 : 0;
}




// set_event_waiting toggles raylib's event-driven idle: when on, EndDrawing() blocks on the OS event
// queue (glfwWaitEvents) until input arrives, so a static UI burns ~0% CPU instead of re-rendering 60
// frames/second. The caller (an immediate-mode loop) turns it OFF whenever it must keep ticking — an
// animation in flight, a network reply streaming — and back ON once everything is at rest. Safe here
// because no work is pending while idle: a new request only starts from user input, which is an event.
void ember_gfx_set_event_waiting(int on) {
    if (on) {
        EnableEventWaiting();
    } else {
        DisableEventWaiting();
    }
}




// had_input reports whether the user did anything this frame — the activity signal that keeps the loop
// awake (and re-arms its coast) before it settles back to event-waiting. Mouse motion, any held or
// just-released button (covers drags end to end), wheel, a window resize, and any keyboard activity all
// count. Keyboard is read TWO ways: draining raylib's key-press queue (GetKeyPressed) catches each fresh
// keystroke (Enter-to-send, ⌘N, typing) — the app reads keys via IsKeyPressed/GetCharPressed so the queue
// is otherwise unused — AND a held-key sweep (IsKeyDown over the desktop keycode range) keeps the loop
// free-running while a key is held DOWN. The latter matters for OS auto-repeat: a repeat is NOT re-queued
// as a press, so without this a held backspace/arrow would coast back into event-waiting between repeats
// and delete in stuttering bursts; staying awake lets IsKeyPressedRepeat fire smoothly each frame.
int ember_gfx_had_input(void) {
    int active = 0;
    while (GetKeyPressed() != 0) {   // drain the unused key queue → a fresh keystroke this frame
        active = 1;
    }
    if (!active) {                   // a HELD key (auto-repeat) is not in the press queue — sweep down-state
        for (int k = 32; k <= 348; k++) {   // KEY_SPACE(32) .. KEY_KB_MENU(348): the desktop keycode range
            if (IsKeyDown(k)) {
                active = 1;
                break;
            }
        }
    }
    Vector2 d = GetMouseDelta();
    if (active || d.x != 0.0f || d.y != 0.0f) {
        return 1;
    }
    if (GetMouseWheelMove() != 0.0f) {
        return 1;
    }
    if (IsWindowResized()) {
        return 1;
    }
    for (int b = 0; b <= 2; b++) {
        if (IsMouseButtonDown(b) || IsMouseButtonReleased(b)) {
            return 1;
        }
    }
    return 0;
}






void ember_gfx_frame_begin(int bg_color) {
    if (g_measure_stats) {   // report the frame just finished: CPU work (the optimisation target, excluding the
        long hits = g_measure_calls - g_measure_ft;   // event-wait idle) and how much text measuring hit FreeType
        fprintf(stderr, "[perf] %5.1f ms work | measure %ld calls, %ld freetype (%.0f%% cached)\n",
                g_work_ms, g_measure_calls, g_measure_ft,
                g_measure_calls > 0 ? 100.0 * (double)hits / (double)g_measure_calls : 0.0);
    }
    g_measure_calls = 0;
    g_measure_ft = 0;
    BeginDrawing();
    ClearBackground(gfx_color(bg_color));
    g_work_t0 = GetTime();   // start the per-frame work clock (stopped at frame_end, before the present/wait)
    g_scale = gfx_backing_scale();   // re-read each frame: tracks the window moving between displays
    g_cmd_count = 0;        // start a fresh command list for this frame
    g_cur_layer = 0;
    g_cur_font = 0;         // text defaults to the embedded font each frame
    g_alpha = 255;          // fade resets to fully opaque each frame
    g_clip_depth = 0;
    SetMouseCursor(MOUSE_CURSOR_DEFAULT);   // reset each frame; a widget re-asserts its cursor while hovered (tape-silent)
    if (g_tape != NULL) {   // snapshot the input that will drive this frame
        g_frame++;
        g_fmx  = GetMouseX();
        g_fmy  = GetMouseY();
        g_fdown = IsMouseButtonDown(MOUSE_BUTTON_LEFT);
    }
}






void ember_gfx_frame_end(void) {
    if (g_measure_stats) {   // stop the work clock before the present + FPS/event wait (which we don't count)
        g_work_ms = (GetTime() - g_work_t0) * 1000.0;
    }
    // Flush the frame's commands in z-order (stable within each layer), then present.
    qsort(g_cmds, (size_t)g_cmd_count, sizeof(GfxCmd), gfx_cmd_cmp);

    // Fold each command's captured fade multiplier into its final alpha, so the tape and the renderer agree.
    // At the default fade (255) this is a no-op (alpha·255/255 == alpha), keeping every un-faded frame identical.
    for (int i = 0; i < g_cmd_count; i++) {
        if (g_cmds[i].fade != 255) {
            g_cmds[i].alpha = g_cmds[i].alpha * g_cmds[i].fade / 255;
        }
    }

    // Record the frame to the UI tape (input + every draw command), if recording.
    if (g_tape != NULL) {
        fprintf(g_tape, "{\"frame\":%d,\"mouse\":[%d,%d],\"down\":%s,\"draws\":[",
                g_frame, g_fmx, g_fmy, g_fdown ? "true" : "false");
        for (int i = 0; i < g_cmd_count; i++) {
            GfxCmd *c = &g_cmds[i];
            if (i > 0) {
                fputc(',', g_tape);
            }
            if (c->kind == GCMD_RECT) {
                fprintf(g_tape, "{\"op\":\"rect\",\"layer\":%d,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"color\":\"%06x\"",
                        c->layer, c->x, c->y, c->w, c->h, (unsigned)(c->color & 0xFFFFFF));
                if (c->alpha < 255) {
                    fprintf(g_tape, ",\"alpha\":%d", c->alpha);
                }
                fputc('}', g_tape);
            } else if (c->kind == GCMD_TEXT) {
                fprintf(g_tape, "{\"op\":\"text\",\"layer\":%d,\"x\":%d,\"y\":%d,\"size\":%d,\"color\":\"%06x\",\"text\":",
                        c->layer, c->x, c->y, c->size, (unsigned)(c->color & 0xFFFFFF));
                gfx_json_str(g_tape, c->text);
                if (c->alpha < 255) {        // omitted when opaque so un-faded goldens are unchanged
                    fprintf(g_tape, ",\"alpha\":%d", c->alpha);
                }
                fputc('}', g_tape);
            } else if (c->kind == GCMD_ROUND) {
                fprintf(g_tape, "{\"op\":\"round\",\"layer\":%d,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"r\":%d,\"color\":\"%06x\",\"alpha\":%d}",
                        c->layer, c->x, c->y, c->w, c->h, c->radius, (unsigned)(c->color & 0xFFFFFF), c->alpha);
            } else if (c->kind == GCMD_STROKE) {
                fprintf(g_tape, "{\"op\":\"stroke\",\"layer\":%d,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"r\":%d,\"thick\":%d,\"color\":\"%06x\",\"alpha\":%d}",
                        c->layer, c->x, c->y, c->w, c->h, c->radius, c->thick, (unsigned)(c->color & 0xFFFFFF), c->alpha);
            } else if (c->kind == GCMD_GRAD) {
                fprintf(g_tape, "{\"op\":\"grad\",\"layer\":%d,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"r\":%d,\"top\":\"%06x\",\"bottom\":\"%06x\",\"alpha\":%d}",
                        c->layer, c->x, c->y, c->w, c->h, c->radius, (unsigned)(c->color & 0xFFFFFF), (unsigned)(c->color2 & 0xFFFFFF), c->alpha);
            } else if (c->kind == GCMD_SHADOW) {
                fprintf(g_tape, "{\"op\":\"shadow\",\"layer\":%d,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"r\":%d,\"alpha\":%d}",
                        c->layer, c->x, c->y, c->w, c->h, c->radius, c->alpha);
            } else if (c->kind == GCMD_CIRCLE) {
                fprintf(g_tape, "{\"op\":\"circle\",\"layer\":%d,\"x\":%d,\"y\":%d,\"r\":%d,\"color\":\"%06x\",\"alpha\":%d}",
                        c->layer, c->x, c->y, c->w, (unsigned)(c->color & 0xFFFFFF), c->alpha);
            } else if (c->kind == GCMD_CLIP_PUSH) {
                fprintf(g_tape, "{\"op\":\"clip_push\",\"layer\":%d,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d}",
                        c->layer, c->x, c->y, c->w, c->h);
            } else {
                fprintf(g_tape, "{\"op\":\"clip_pop\",\"layer\":%d}", c->layer);
            }
        }
        fputs("]}\n", g_tape);
        fflush(g_tape);
    }

    // Draw in LOGICAL points. raylib's HiDPI projection already maps logical coordinates onto the
    // physical framebuffer (a 1100-pt window fills a 2200-px buffer), and BeginScissorMode DPI-scales
    // the clips below the same way on Apple — so NO camera is needed. (OFI-060 added a Camera2D whose
    // zoom == g_scale ON TOP of that projection, double-scaling the whole UI to 2× its size on Retina;
    // removed. g_scale now only sizes the glyph bake so text stays pixel-crisp at the device size.)
    g_clip_depth = 0;
    for (int i = 0; i < g_cmd_count; i++) {
        GfxCmd *c = &g_cmds[i];
        switch (c->kind) {
            case GCMD_RECT:
                DrawRectangle(c->x, c->y, c->w, c->h, gfx_rgba(c->color, c->alpha));
                break;
            case GCMD_ROUND: {
                Rectangle r = { (float)c->x, (float)c->y, (float)c->w, (float)c->h };
                float rn = gfx_roundness(c->radius, c->w, c->h);
                if (rn <= 0.0f) {
                    DrawRectangleRec(r, gfx_rgba(c->color, c->alpha));
                } else {
                    DrawRectangleRounded(r, rn, 8, gfx_rgba(c->color, c->alpha));
                }
                break;
            }
            case GCMD_STROKE: {
                Rectangle r = { (float)c->x, (float)c->y, (float)c->w, (float)c->h };
                float rn = gfx_roundness(c->radius, c->w, c->h);
                DrawRectangleRoundedLinesEx(r, rn, 8, (float)c->thick, gfx_rgba(c->color, c->alpha));
                break;
            }
            case GCMD_GRAD: {
                // A subtle vertical gradient on a rounded shape: fill the rounded base in the top
                // colour (covers the corners), then lay a straight top→bottom gradient over the
                // body inset by the corner radius so the rounded corners stay clean.
                Rectangle r = { (float)c->x, (float)c->y, (float)c->w, (float)c->h };
                float rn = gfx_roundness(c->radius, c->w, c->h);
                if (rn <= 0.0f) {
                    DrawRectangleGradientV(c->x, c->y, c->w, c->h,
                                           gfx_rgba(c->color, c->alpha), gfx_rgba(c->color2, c->alpha));
                } else {
                    DrawRectangleRounded(r, rn, 8, gfx_rgba(c->color, c->alpha));
                    int inset = c->radius;
                    if (inset * 2 < c->h) {
                        DrawRectangleGradientV(c->x, c->y + inset, c->w, c->h - inset * 2,
                                               gfx_rgba(c->color, c->alpha),
                                               gfx_rgba(c->color2, c->alpha));
                    }
                }
                break;
            }
            case GCMD_SHADOW: {
                // No GPU blur in raylib, so feather a soft drop shadow: stack a handful of
                // rounded rects, each a ring larger and fainter, offset slightly downward. The
                // result reads as elevation without a texture or shader.
                int   steps = 7;
                float a0    = (float)c->alpha;
                for (int s = steps; s >= 1; s--) {
                    int grow = s * 2;
                    int oy   = s;                              // cast downward
                    Rectangle r = { (float)(c->x - grow), (float)(c->y - grow + oy),
                                    (float)(c->w + grow * 2), (float)(c->h + grow * 2) };
                    float rn = gfx_roundness(c->radius + grow, (int)r.width, (int)r.height);
                    int   a  = (int)(a0 / (float)(s * s + 1));   // quadratic falloff
                    Color sh = { 0, 0, 0, (unsigned char)(a > 255 ? 255 : a) };
                    DrawRectangleRounded(r, rn, 8, sh);
                }
                break;
            }
            case GCMD_CIRCLE:
                DrawCircle(c->x, c->y, (float)c->w, gfx_rgba(c->color, c->alpha));
                break;
            case GCMD_TEXT: {
                Vector2 pos = { (float)c->x, (float)c->y };
                int phys_px = (int)lroundf((float)c->size * g_scale);
                Font *f = gfx_font_for(c->font, phys_px, c->text);
                if (f != NULL) {
                    // The Font is baked at phys_px == size×g_scale; drawn at logical c->size it
                    // scales by c->size/phys_px == 1/g_scale, and raylib's HiDPI projection then
                    // maps logical→physical by g_scale — net 1:1, so the hinted bitmap reaches the
                    // screen pixel-for-pixel on every display.
                    DrawTextEx(*f, c->text, pos, (float)c->size,
                               gfx_text_spacing(c->size), gfx_rgba(c->color, c->alpha));
                }
                free(c->text);
                c->text = NULL;
                break;
            }
            case GCMD_CLIP_PUSH: {
                // Intersect with the clip currently in force, so nested clips compose.
                int nx = c->x, ny = c->y, nw = c->w, nh = c->h;
                if (g_clip_depth > 0) {
                    int *p = g_clip[g_clip_depth - 1];
                    int ax = nx > p[0] ? nx : p[0];
                    int ay = ny > p[1] ? ny : p[1];
                    int ar = (nx + nw) < (p[0] + p[2]) ? (nx + nw) : (p[0] + p[2]);
                    int ab = (ny + nh) < (p[1] + p[3]) ? (ny + nh) : (p[1] + p[3]);
                    nx = ax; ny = ay;
                    nw = ar - ax < 0 ? 0 : ar - ax;
                    nh = ab - ay < 0 ? 0 : ab - ay;
                }
                if (g_clip_depth < GFX_CLIP_MAX) {
                    g_clip[g_clip_depth][0] = nx; g_clip[g_clip_depth][1] = ny;
                    g_clip[g_clip_depth][2] = nw; g_clip[g_clip_depth][3] = nh;
                    g_clip_depth++;
                }
                BeginScissorMode(nx, ny, nw, nh);
                break;
            }
            case GCMD_CLIP_POP:
                if (g_clip_depth > 0) {
                    g_clip_depth--;
                }
                if (g_clip_depth > 0) {
                    int *p = g_clip[g_clip_depth - 1];
                    BeginScissorMode(p[0], p[1], p[2], p[3]);   // restore the enclosing clip
                } else {
                    EndScissorMode();
                }
                break;
        }
    }
    if (g_clip_depth > 0) {     // defensive: an unbalanced push shouldn't leak the scissor
        EndScissorMode();
        g_clip_depth = 0;
    }
    g_cmd_count = 0;

    // Auto-capture (EMBER_CAPTURE): on the target frame, queue the screenshot and flag the
    // window to close, so the program exits right after presenting this fully-drawn frame.
    if (g_autocap_at >= 0 && g_capture_path[0] == '\0') {
        if (g_autocap_seen == g_autocap_at) {
            size_t n = strlen(g_autocap_path);
            memcpy(g_capture_path, g_autocap_path, n + 1);
            g_force_close = 1;
        }
        g_autocap_seen++;
    }

    // Honour a queued screenshot now: the whole frame is drawn but not yet presented.
    // raylib batches geometry, so flush it to the framebuffer first (rlDrawRenderBatchActive)
    // or the pixels read back would be this frame's draws still pending — a blank/stale image.
    // We read with LoadImageFromScreen + ExportImage rather than TakeScreenshot because the
    // latter prepends raylib's base path and mangles an absolute path; ExportImage writes to
    // the exact path we were given (format chosen by the .png/.jpg/... extension).
    if (g_capture_path[0] != '\0') {
        rlDrawRenderBatchActive();
        Image shot = LoadImageFromScreen();
        ExportImage(shot, g_capture_path);
        UnloadImage(shot);
        g_capture_path[0] = '\0';
    }

    EndDrawing();
}


// ember_gfx_frame_capture queues a PNG screenshot of the CURRENT frame, written when the
// frame is presented (see frame_end). Call it between frame_begin and frame_end. Returns 1
// if queued, 0 if the path is empty or too long. The image is the physical framebuffer, so
// on a Retina display it is captured at the full device resolution (2× logical) — crisp for
// docs and visual-regression goldens. The instrument behind Flare's visual work.
int ember_gfx_frame_capture(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return 0;
    }
    size_t n = strlen(path);
    if (n >= sizeof(g_capture_path)) {
        return 0;
    }
    memcpy(g_capture_path, path, n + 1);
    return 1;
}






void ember_gfx_set_layer(int z) {
    g_cur_layer = z;       // commands that follow render on this layer
}






// ember_gfx_set_cursor maps an Ember-abstract cursor shape (stable, raylib-independent) to the OS pointer.
// Like set_layer it mutates GL/OS state directly — it pushes NO draw command, so it never appears in the tape
// and cannot perturb a render golden. frame_begin resets to the default each frame, so a widget only needs to
// re-assert its cursor while it is hovered/active; nothing has to "unset" it.
void ember_gfx_set_cursor(int shape) {
    int rl = MOUSE_CURSOR_DEFAULT;
    if (shape == 1) {
        rl = MOUSE_CURSOR_RESIZE_EW;        // horizontal resize (↔) — a vertical splitter bar
    } else if (shape == 2) {
        rl = MOUSE_CURSOR_RESIZE_NS;        // vertical resize (↕) — a horizontal splitter bar
    } else if (shape == 3) {
        rl = MOUSE_CURSOR_POINTING_HAND;    // a clickable affordance (links)
    } else if (shape == 4) {
        rl = MOUSE_CURSOR_IBEAM;            // editable / selectable text
    }
    SetMouseCursor(rl);
}






void ember_gfx_clip_push(int x, int y, int w, int h) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_CLIP_PUSH;
    c->x = x; c->y = y; c->w = w; c->h = h;
}






void ember_gfx_clip_pop(void) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_CLIP_POP;
}






int ember_gfx_tape_open(const char *path) {
    if (g_tape != NULL) {
        fclose(g_tape);
    }
    g_tape = fopen(path, "w");
    g_frame = 0;
    return g_tape != NULL ? 1 : 0;
}






void ember_gfx_tape_close(void) {
    if (g_tape != NULL) {
        fclose(g_tape);
        g_tape = NULL;
    }
}






void ember_gfx_tape_mark(const char *kind, const char *label) {
    if (g_tape == NULL) {
        return;       // no-op when not recording, so std/ui can always call it
    }
    fprintf(g_tape, "{\"frame\":%d,\"event\":\"%s\",\"label\":", g_frame, kind);
    gfx_json_str(g_tape, label);
    fputs("}\n", g_tape);
    fflush(g_tape);
}






void ember_gfx_draw_rect(int x, int y, int w, int h, int color) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_RECT;
    c->x = x; c->y = y; c->w = w; c->h = h;
    c->color = color;
}






void ember_gfx_draw_text(const char *text, int x, int y, int size, int color) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_TEXT;
    c->x = x; c->y = y; c->size = size;
    c->color = color;
    c->font = g_cur_font;       // capture the active font so the deferred flush uses it
    c->text = strdup(text);
}






void ember_gfx_fill_round(int x, int y, int w, int h, int radius, int color, int alpha) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_ROUND;
    c->x = x; c->y = y; c->w = w; c->h = h;
    c->radius = radius; c->color = color; c->alpha = alpha;
}






void ember_gfx_stroke_round(int x, int y, int w, int h, int radius, int thick, int color, int alpha) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_STROKE;
    c->x = x; c->y = y; c->w = w; c->h = h;
    c->radius = radius; c->thick = thick; c->color = color; c->alpha = alpha;
}






void ember_gfx_fill_grad(int x, int y, int w, int h, int radius, int top, int bottom, int alpha) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_GRAD;
    c->x = x; c->y = y; c->w = w; c->h = h;
    c->radius = radius; c->color = top; c->color2 = bottom; c->alpha = alpha;
}






void ember_gfx_shadow(int x, int y, int w, int h, int radius, int alpha) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_SHADOW;
    c->x = x; c->y = y; c->w = w; c->h = h;
    c->radius = radius; c->alpha = alpha; c->color = 0;
}






void ember_gfx_fill_circle(int cx, int cy, int r, int color, int alpha) {
    GfxCmd *c = gfx_push_cmd();
    c->kind = GCMD_CIRCLE;
    c->x = cx; c->y = cy; c->w = r;
    c->color = color; c->alpha = alpha;
}






int ember_gfx_key_down(int keycode) {
    return IsKeyDown(keycode) ? 1 : 0;
}






int ember_gfx_mouse_x(void) {
    return GetMouseX();
}






int ember_gfx_mouse_y(void) {
    return GetMouseY();
}






int ember_gfx_mouse_down(void) {
    return IsMouseButtonDown(MOUSE_BUTTON_LEFT) ? 1 : 0;
}


int ember_gfx_mouse_right_down(void) {
    return IsMouseButtonDown(MOUSE_BUTTON_RIGHT) ? 1 : 0;
}






int ember_gfx_measure_text(const char *text, int size) {
    g_measure_calls++;
    if (g_scale != g_measure_cache_scale) {            // DPI/display change → cached widths are stale
        gfx_measure_cache_flush();
        g_measure_cache_scale = g_scale;
    }
    uint64_t h = gfx_measure_hash(text, g_cur_font, size);
    if (h == 0) {                                      // reserve 0 to mean "empty slot"
        h = 1;
    }
    MeasureEntry *e = &g_measure_cache[h & (MEASURE_CACHE_SIZE - 1)];
    if (e->hash == h && e->font == g_cur_font && e->size == size
        && e->text != NULL && strcmp(e->text, text) == 0) {
        return e->width;                               // HIT — no FreeType this frame
    }
    // MISS: measure on the baked Font at logical `size` (matches the 1/g_scale draw scale exactly, so
    // widget auto-sizing and the rendered glyph runs stay in lockstep), then store, evicting any slot peer.
    g_measure_ft++;
    int phys_px = (int)lroundf((float)size * g_scale);
    Font *f = gfx_font_for(g_cur_font, phys_px, text);
    if (f == NULL) {
        return 0;
    }
    Vector2 m = MeasureTextEx(*f, text, (float)size, gfx_text_spacing(size));
    int width = (int)m.x;
    char *copy = strdup(text);
    if (copy != NULL) {                                // on OOM, just don't cache this one
        free(e->text);
        e->text  = copy;
        e->hash  = h;
        e->font  = g_cur_font;
        e->size  = size;
        e->width = width;
    }
    return width;
}






// The active font's LINE HEIGHT (ascender + |descender|) in LOGICAL points at `size`. draw_text places
// the line-box top at the given y, but the glyphs sit by the font's metrics — the ascender reserves
// space above the caps — so a text laid out / highlighted as a `size`-tall box is top-biased. Callers
// use this true line height to centre text vertically and to size a selection highlight / caret that
// actually wraps the glyphs symmetrically.
int ember_gfx_text_line_height(int size) {
    int slot = g_cur_font;
    if (slot < 0 || slot >= g_font_count || !g_fonts[slot].loaded) {
        slot = 0;
    }
    if (g_font_count == 0 || !g_fonts[slot].loaded) {
        return size;                          // no face yet — fall back to the em size
    }
    int phys_px = (int)lroundf((float)size * g_scale);
    if (phys_px < 1) {
        phys_px = 1;
    }
    FT_Face face = g_fonts[slot].face;
    if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt)phys_px) != 0) {
        return size;
    }
    // ascender is +, descender is − (26.6 fixed point); their span is the glyph line box, no line gap.
    long span = face->size->metrics.ascender - face->size->metrics.descender;
    int lh = (int)lroundf((float)(span >> 6) / g_scale);   // physical px → logical points
    if (lh < size) {
        lh = size;                            // never shorter than the em box
    }
    return lh;
}






int ember_gfx_char_pressed(void) {
    return GetCharPressed();          // next queued Unicode char this frame, 0 if none
}






int ember_gfx_key_pressed(int keycode) {
    return IsKeyPressed(keycode) ? 1 : 0;   // true only on the frame it goes down
}






int ember_gfx_key_repeat(int keycode) {
    // true on each auto-repeat tick while the key is held (after the OS repeat delay) — pair with
    // key_pressed for "fire once, then repeat" editing keys (backspace, arrows, delete).
    return IsKeyPressedRepeat(keycode) ? 1 : 0;
}






int ember_gfx_load_font(const char *path) {
    // Open a TTF/OTF from disk as a fresh FreeType face. Per-size glyph atlases are baked lazily on
    // first use (gfx_font_for), so this is cheap. Returns the slot id, or -1 if FreeType is
    // unavailable, the registry is full, or the file won't parse (the caller falls back to font 0).
    if (!g_ft_ready || g_font_count >= GFX_FONT_MAX) {
        return -1;
    }
    FT_Face face;
    if (FT_New_Face(g_ft, path, 0, &face) != 0) {
        return -1;          // unreadable / not a font FreeType understands
    }
    memset(&g_fonts[g_font_count], 0, sizeof(GfxFont));
    g_fonts[g_font_count].face = face;
    g_fonts[g_font_count].loaded = 1;
    return g_font_count++;
}






void ember_gfx_set_font(int id) {
    // Select the font slot for the text that follows this frame (ignored if out of range, so a
    // failed load that left the caller using -1 just keeps the default font).
    if (id >= 0 && id < g_font_count) {
        g_cur_font = id;
    }
}






void ember_gfx_clipboard_set(const char *text) {
    SetClipboardText(text);
}






const char *ember_gfx_clipboard_get(void) {
    const char *p = GetClipboardText();   // owned by GLFW, valid until the next call — copy now
    return p != NULL ? p : "";
}


// dropped_files() -> the paths of files dragged onto the window THIS frame, '\n'-joined (empty if none).
// The result is owned here (freed on the NEXT call, like clipboard_get's GLFW buffer) — the VM copies it now.
const char *ember_gfx_dropped_files(void) {
    static char *buf = NULL;
    free(buf);                             // release the previous result (free(NULL) is a no-op)
    buf = NULL;
    if (!IsFileDropped()) {
        return "";
    }
    FilePathList list = LoadDroppedFiles();
    size_t total = 1;                      // trailing '\0'
    for (unsigned int i = 0; i < list.count; i++) {
        total += strlen(list.paths[i]) + 1;   // path + its separator ('\n' or the final '\0')
    }
    buf = (char *)malloc(total);
    if (buf == NULL) {
        UnloadDroppedFiles(list);
        return "";
    }
    size_t off = 0;
    for (unsigned int i = 0; i < list.count; i++) {
        if (i > 0) {
            buf[off++] = '\n';
        }
        size_t l = strlen(list.paths[i]);
        memcpy(buf + off, list.paths[i], l);
        off += l;
    }
    buf[off] = '\0';
    UnloadDroppedFiles(list);
    return buf;
}






int ember_gfx_screen_width(void) {
    return GetScreenWidth();
}






int ember_gfx_screen_height(void) {
    return GetScreenHeight();
}






int ember_gfx_mouse_wheel(void) {
    float m = GetMouseWheelMove();          // +1 per notch up, -1 down (fractional on trackpads)
    if (m > 0.0f) {
        return (int)(m + 0.5f);
    }
    if (m < 0.0f) {
        return (int)(m - 0.5f);
    }
    return 0;
}

#endif // EMBER_GRAPHICS
