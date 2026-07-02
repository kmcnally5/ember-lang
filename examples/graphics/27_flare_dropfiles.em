// 27_flare_dropfiles.em — file drag-and-drop via the `dropped_files()` graphics native (MANIFESTO §5g).
// Drag one or more files from Finder onto the window; each is staged as an attachment chip (filename + ×).
// Click a chip to remove it. `dropped_files()` returns the newline-joined paths dropped THIS frame ("" when
// none) — raylib's IsFileDropped/LoadDroppedFiles surfaced as one string native, the same way the app's
// composer stages attachments.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/27_flare_dropfiles.em

import "std/draw" as draw
import "std/flare" as flare


fn basename(path: string) -> string {
    let parts = path.split("/")
    if parts.len() > 0 {
        return parts[parts.len() - 1]
    }
    return path
}


fn main() -> int {
    draw.window(520, 360, "Drop files")
    var f = flare.new()
    var files: [string] = []

    loop {
        if draw.closing() {
            break
        }
        let dropped = dropped_files()
        if dropped.len() > 0 {
            let paths = dropped.split("\n")
            var di = 0
            loop {
                if di == paths.len() {
                    break
                }
                if paths[di].len() > 0 {
                    files.append(paths[di])
                }
                di = di + 1
            }
        }

        draw.begin(f.bg())
        f.begin()
        f.heading("Drag files onto this window")
        f.text_muted("{files.len()} file(s) staged — click a chip to remove it.")
        f.strut(0, 8)

        var remove = 0 - 1
        var i = 0
        loop {
            if i == files.len() {
                break
            }
            f.key("f{i}")
            f.row(flare.START, flare.CENTER)
            if f.ghost_button("× " + basename(files[i])) {
                remove = i
            }
            f.text_muted(files[i])
            f.end()
            f.key_clear()
            i = i + 1
        }
        if remove >= 0 {
            files.remove_at(remove)
        }

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
