// flare_chat.em — the Claude desktop app on std/flare (the declarative widget kit), the Flare-native
// sibling of the raw-intrinsics gui.em. It dogfoods Flare — sidebar, scrollable transcript, wrapped
// prose, a real composer — talks to the live Anthropic API, and is now an AGENT: it can call tools
// (`read_file` to inspect local files, `write_file` to save text under the launch directory), running the
// tool_use → tool_result loop until Claude answers, with an editable system prompt in Settings. The Anthropic
// wire layer now lives in the reusable `anthropic` client (over `std/http`); this file is just the app. The
// transcript is a list of content-block Turns (text / tool_use / tool_result). Build + run from the repo root:
//
//   ANTHROPIC_API_KEY=sk-ant-... ./public/claude-desktop/run-flare.sh
//   # or: make net-graphics && ANTHROPIC_API_KEY=… build/emberc-net-gfx --emit=run public/claude-desktop/flare_chat.em
//
// It needs emberc-NET-gfx (libcurl for the std/http transport + the parallel runtime for the worker fiber/channels),
// like gui.em. Without ANTHROPIC_API_KEY it still runs; sending just prints a reminder.
//
// Flare features this app drove into the kit: sized/growing containers (sidebar | main | pinned
// composer), full-width cards, wrapped paragraphs, painted panels, a multi-line text_area composer, a scrollable
// viewport, rich markdown (code/quotes), and live streaming — and now a SETTINGS dialog built on Flare's
// new reusable f.modal (a centred floating panel over a dimmed scrim) and f.segmented (a single-choice
// control), driving appearance / model / max-tokens / text-size. Remaining: a max transcript column width.
import "std/draw" as draw
import "std/flare" as flare
import "std/json" as json
import "anthropic" as api
import "ollama" as oll

// Keyboard shortcuts (raylib keycodes): ⌘/Ctrl with +/- to zoom, N for a new chat.
let KEY_SUPER_L = 343
let KEY_SUPER_R = 347
let KEY_CTRL_L  = 341
let KEY_EQUAL   = 61    // the +/= key (⌘+ zoom in)
let KEY_MINUS   = 45    // ⌘- zoom out
let KEY_N       = 78
let KEY_ESCAPE  = 256   // stop generation






// ---- JSON request + response — built and parsed with std/json (no hand-rolled escaping) ----

// tool_defs is the tool catalogue advertised to the model: read_file (inspect a file) and write_file
// (create/overwrite a file under the launch directory). Each entry is {name, description, input_schema}
// per the Messages API; the description is the model's only cue for WHEN to reach for a tool.
fn tool_defs() -> json.Json {
    return json.arr([
        json.obj([
            json.member("name", json.str("read_file")),
            json.member("description", json.str("Read a UTF-8 text file from the local filesystem and return its full contents. Use this to inspect source code, configuration, or any text file the user refers to BEFORE answering questions about it — do not guess at file contents.")),
            json.member("input_schema", json.obj([
                json.member("type", json.str("object")),
                json.member("properties", json.obj([
                    json.member("path", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("Path to the file to read — absolute, or relative to the directory the app was launched from."))
                    ]))
                ])),
                json.member("required", json.arr([json.str("path")]))
            ]))
        ]),
        json.obj([
            json.member("name", json.str("write_file")),
            json.member("description", json.str("Create or overwrite a UTF-8 text file under the directory the app was launched from, then report the result. The path MUST be relative (no leading '/', no '..') for safety. Use this to save code or text you have produced so the user can open it.")),
            json.member("input_schema", json.obj([
                json.member("type", json.str("object")),
                json.member("properties", json.obj([
                    json.member("path", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("Destination path, relative to the launch directory (e.g. \"notes/reply.txt\")."))
                    ])),
                    json.member("content", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("The full text to write to the file."))
                    ]))
                ])),
                json.member("required", json.arr([json.str("path"), json.str("content")]))
            ]))
        ])
    ])
}






// ---- tool execution — the agent side: run a tool call locally and return its result text ----

// run_tool dispatches a tool_use by name to its handler and returns the result string that goes back to the
// model as the tool_result content. An unknown tool returns an error string (the model can recover from it).
fn run_tool(name: string, input: string) -> string {
    if name == "read_file" {
        return run_read_file(input)
    }
    if name == "write_file" {
        return run_write_file(input)
    }
    return "Error: unknown tool \"{name}\"."
}






// run_read_file executes the read_file tool: parse the path, read it, cap the size. read_file is an Ember
// builtin; a missing/empty/unreadable file comes back as "" → an error result so the model knows it failed.
fn run_read_file(input: string) -> string {
    let path = api.arg_str(input, "path")
    if path.len() == 0 {
        return "Error: read_file requires a \"path\" string argument."
    }
    let content = read_file(path)
    if content.len() == 0 {
        return "Error: could not read \"{path}\" — it is missing, empty, or not readable."
    }
    return api.cap_text(content, 60000)
}






// path_is_safe gates write_file: only a RELATIVE path under the launch directory is allowed — no
// absolute path (leading '/') and no '..' segment that could escape upward. A blunt, readable guard;
// it errs toward refusal (even an innocent ".." inside a name is rejected), which is the safe bias.
fn path_is_safe(path: string) -> bool {
    let cs = path.chars()
    if cs.len() == 0 {
        return false
    }
    if cs[0] == "/" {
        return false
    }
    if path.split("..").len() > 1 {
        return false
    }
    return true
}






// run_write_file executes the write_file tool: validate the path, write the content, then read it
// back to confirm the bytes actually landed (the write_file builtin is best-effort and silent on
// failure), so the model gets a truthful success-or-error result rather than an optimistic guess.
fn run_write_file(input: string) -> string {
    let path = api.arg_str(input, "path")
    if path.len() == 0 {
        return "Error: write_file requires a \"path\" string argument."
    }
    if !path_is_safe(path) {
        return "Error: refusing to write \"{path}\" — only a relative path under the launch directory is allowed (no leading '/', no '..')."
    }
    let content = api.arg_str(input, "content")
    write_file(path, content)
    let back = read_file(path)
    if back.len() == 0 && content.len() > 0 {
        return "Error: the write to \"{path}\" did not take — does the target directory exist and is it writable?"
    }
    return "Wrote \"{path}\" ({content.chars().len()} chars)."
}






// model_id / model_label map the picker index (0 Opus · 1 Sonnet · 2 Haiku) to the API id and a label.
fn model_id(idx: int) -> string {
    if idx == 1 {
        return api.MODEL_SONNET
    }
    if idx == 2 {
        return api.MODEL_HAIKU
    }
    return api.MODEL_OPUS
}






fn model_label(idx: int) -> string {
    if idx == 1 {
        return "Sonnet 4.6"
    }
    if idx == 2 {
        return "Haiku 4.5"
    }
    return "Opus 4.8"
}






// tokens_for maps the max-tokens picker index (0 1K · 1 2K · 2 4K · 3 8K) to the API max_tokens value.
fn tokens_for(idx: int) -> int {
    if idx == 0 {
        return 1024
    }
    if idx == 2 {
        return 4096
    }
    if idx == 3 {
        return 8192
    }
    return 2048
}






// chosen_model resolves the model id to send: an explicit ANTHROPIC_MODEL pin wins, else the picker's choice.
// Shared by the first send and the agentic re-send after a tool result, so they can never drift apart.
fn chosen_model(model_idx: int, use_env: bool, env_model: string) -> string {
    if use_env {
        return env_model
    }
    return model_id(model_idx)
}






// provider_label names the active backend for the Inspector and toolbar: the hosted Anthropic API, or
// a model running locally under Ollama. The Ollama path needs no API key and never leaves the machine.
fn provider_label(provider: int) -> string {
    if provider == 1 {
        return "Ollama (local)"
    }
    return "Claude (API)"
}






// send_turn dispatches one request to the ACTIVE provider's worker: Claude gets the Anthropic Messages
// body (with the app's tool catalogue) on its channel; Ollama gets the OpenAI-compatible chat body (no
// tools in this MVP) on its own channel. Centralised so the first send, the agentic re-send after a
// tool result, and Retry can never drift in how they build or route a request.
fn send_turn(provider: int, anth_ch: Channel<string>, oll_ch: Channel<string>, anth_model: string, ollama_model: string, max_tokens: int, sys: string, turns: [api.Turn]) {
    if provider == 1 {
        send(oll_ch, oll.build_request(ollama_model, max_tokens, sys, turns, true))
    } else {
        send(anth_ch, api.build_request(anth_model, max_tokens, sys, tool_defs(), turns))
    }
}






// Conv is one in-memory conversation: a title (derived from the first user turn) plus its own transcript.
// The app keeps the ACTIVE conversation in a flat working `turns` array and writes the whole array back into
// its Conv on a switch — never mutating an array reached through an index (OFI-072).
struct Conv {
    title: string
    turns: [api.Turn]
}






// ellipsize trims a label to at most n code points (newlines → spaces) with a trailing ellipsis,
// so a long first message still fits the narrow sidebar.
fn ellipsize(s: string, n: int) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() || i == n {
            break
        }
        if char_code(cs[i]) == 10 {
            out.append(" ")
        } else {
            out.append(cs[i])
        }
        i = i + 1
    }
    if cs.len() > n {
        out.append("…")
    }
    return concat(out)
}






// title_for names a conversation by its first user message (Claude-app style); empty until you speak.
fn title_for(turns: [api.Turn]) -> string {
    var i = 0
    loop {
        if i == turns.len() {
            break
        }
        if turns[i].role == 0 && turns[i].kind == 0 {
            return ellipsize(turns[i].text, 80)   // store a generous title; each view ellipsizes to its own width
        }
        i = i + 1
    }
    return "New chat"
}






// claude_turn renders one assistant turn the way the real app does: the Claude avatar (the "*" spark)
// beside a column of the "Claude" label and the reply as rich Markdown, then (for committed turns) a
// hover-style action row of ghost buttons. Copy puts the reply on the clipboard; Retry is returned to the
// caller to regenerate. `key` scopes the per-message buttons; `show_actions` hides them mid-stream.
fn claude_turn(mut f: flare.Flare, body: string, cw: int, key: string, show_actions: bool) -> bool {
    var retry = false
    f.key(key)
    f.row(flare.START, flare.START)
    f.avatar("*")
    f.strut(8, 0)
    f.column(flare.START, flare.START)
    f.text_muted("Claude")
    f.markdown(body, cw - 56)
    if show_actions {
        f.row(flare.START, flare.CENTER)
        if f.ghost_button("Copy") {
            clipboard_set(body)
            f.toast("Copied to clipboard")
        }
        if f.ghost_button("Retry") {
            retry = true
        }
        f.end()
    }
    f.end()
    f.end()
    f.key_clear()
    return retry
}






// user_turn renders one user turn as a rounded chat bubble (Flare's new f.bubble): a "You" label above
// the message (plain prose, no Markdown — the user's own text).
fn user_turn(mut f: flare.Flare, body: string, cw: int) {
    f.bubble_begin()
    f.text_muted("You")
    f.paragraph(body, cw - 24)
    f.bubble_end()
}






// thinking_turn is the assistant's pre-stream placeholder: the avatar beside a muted "thinking" line with a
// "- \ | /" spinner animated off the frame counter.
fn thinking_turn(mut f: flare.Flare, tick: int) {
    f.row(flare.START, flare.CENTER)
    f.avatar("*")
    f.strut(8, 0)
    f.text_muted("Claude is thinking " + flare.spinner(tick))
    f.end()
}






// tool_card renders one tool call the way an agent UI does: a subtle panel headed with the tool and its
// argument ("read_file("path")"), then — once the call returns — a capped preview of its output. `has_result`
// is false only for the edge case where the result turn isn't in the transcript yet. Kept in-app for v1; if it
// generalises (a disclosure / code-output card) it can graduate into Flare.
fn tool_card(mut f: flare.Flare, key: string, name: string, input: string, result: string, has_result: bool, cw: int) {
    f.key(key)
    f.panel_begin(flare.START, flare.START)
    f.row(flare.START, flare.CENTER)
    f.text_muted("used tool")
    f.strut(6, 0)
    f.label(name + "(" + tool_arg_summary(name, input) + ")")
    f.end()
    if has_result {
        f.divider()
        f.paragraph(api.cap_text(result, 700), cw - 48)
    } else {
        f.text_muted("running…")
    }
    f.end()
    f.key_clear()
}






// tool_arg_summary renders a tool's args compactly for the card header: read_file shows its quoted path; any
// other tool falls back to the raw args JSON.
fn tool_arg_summary(name: string, input: string) -> string {
    if name == "read_file" {
        let p = api.arg_str(input, "path")
        if p.len() > 0 {
            return "\"" + p + "\""
        }
    }
    return input
}






// store_path is where chats persist: $EMBER_CLAUDE_STORE if set, else a dotfile in $HOME (user-scoped, no
// mkdir needed). NOT the repo/cwd — chat history is user data, and the app runs from the repo root.
fn store_path() -> string {
    let custom = env("EMBER_CLAUDE_STORE")
    if custom.len() > 0 {
        return custom
    }
    return env("HOME") + "/.ember-claude-history.json"
}






// turn_json serialises one turn to its store JSON: always {role, text}; for a tool turn (kind != 0) also
// {kind, tid}, and for a tool_use {tname, tinput}. Plain text turns stay minimal. Fields are passed in (read
// IN PLACE by the caller) so we never move a Turn out of its array.
fn turn_json(role: int, text: string, kind: int, tid: string, tname: string, tinput: string) -> json.Json {
    var mem: [json.Member] = []
    mem.append(json.member("role", json.num(role)))
    mem.append(json.member("text", json.str(text)))
    if kind != 0 {
        mem.append(json.member("kind", json.num(kind)))
        mem.append(json.member("tid", json.str(tid)))
        if kind == 1 {
            mem.append(json.member("tname", json.str(tname)))
            mem.append(json.member("tinput", json.str(tinput)))
        }
    }
    return json.obj(mem)
}






// save_store writes the whole store to disk as versioned JSON (v3): every conversation (a list of typed
// turns) PLUS the settings (model, max-tokens, theme, zoom), so the app restores exactly where you left off.
// The ACTIVE conversation's live transcript lives in the working `turns` array (not yet written back into
// convos[active]), so it is serialized from that; the rest from their Conv. Paired with the startup load,
// the convos are the nested-aggregate round-trip test: `[Conv]` (structs of `[api.Turn]`) → JSON → fresh structs.
fn save_store(convos: [Conv], active: int, turns: [api.Turn], model_idx: int, tok_idx: int, dark: bool, zoom: int, system: string, dock: flare.DockTree, provider: int, ollama_model: string) {
    var cjs: [json.Json] = []
    var i = 0
    loop {
        if i == convos.len() {
            break
        }
        var tjs: [json.Json] = []
        var ttl = ""
        if i == active {
            ttl = title_for(turns)
            var j = 0
            loop {
                if j == turns.len() {
                    break
                }
                tjs.append(turn_json(turns[j].role, turns[j].text, turns[j].kind, turns[j].tool_id, turns[j].tool_name, turns[j].tool_input))
                j = j + 1
            }
        } else {
            ttl = convos[i].title
            let ct = convos[i].turns.clone()                // deep-copy out so the stored conversation array isn't aliased by the mutable working copy
            var j = 0
            loop {
                if j == ct.len() {
                    break
                }
                tjs.append(turn_json(ct[j].role, ct[j].text, ct[j].kind, ct[j].tool_id, ct[j].tool_name, ct[j].tool_input))
                j = j + 1
            }
        }
        cjs.append(json.obj([
            json.member("title", json.str(ttl)),
            json.member("turns", json.arr(tjs))
        ]))
        i = i + 1
    }
    let root = json.obj([
        json.member("v", json.num(5)),         // v5: + provider + ollama_model (loaded by field presence)
        json.member("active", json.num(active)),
        json.member("model", json.num(model_idx)),
        json.member("toks", json.num(tok_idx)),
        json.member("dark", json.boolean(dark)),
        json.member("zoom", json.num(zoom)),
        json.member("system", json.str(system)),
        json.member("provider", json.num(provider)),    // v5: selected backend (0 Claude · 1 Ollama)
        json.member("ollama_model", json.str(ollama_model)),
        json.member("dock", dock.to_json()),            // OFI-112: persist the docked workspace layout
        json.member("convos", json.arr(cjs))
    ])
    write_file(store_path(), json.stringify(root))
}






// build_workspace lays out the default docked workspace: Conversations | Chat | Inspector. Chat is the
// pinned anchor in the centre; Conversations docks on the left, the Inspector on the right. The user
// resizes the panels by dragging the dividers and closes Conversations/Inspector with their ✕; the Chat
// toolbar re-docks whichever is closed, and the Inspector's "Reset layout" rebuilds this default.
fn build_workspace() -> flare.DockTree {
    var d = flare.dock_new()
    let chat = d.add_root("Chat")
    let _ = d.split(chat, "Inspector", true, 0.76)              // (Conv|Chat) 76% | Inspector 24%
    let _ = d.split_before(chat, "Conversations", true, 0.26)   // Conversations 26% | Chat 74%
    return d
}


// panel_cw returns docked panel `id`'s inner content width (body minus the float's two-sided padding),
// clamped to [floor, cap], so a panel's prose wraps to its CURRENT width as the user resizes it.
fn panel_cw(mut f: flare.Flare, id: string, floor: int, cap: int) -> int {
    var w = floor
    match f.ds.get(id) {
        case Some(r) { w = r.w - f.ui.style.pad * 2 }
        case None {}
    }
    if w > cap { w = cap }
    if w < floor { w = floor }
    return w
}


fn main() -> int {
    draw.window(1200, 760, "Claude — Flare")
    var f = flare.new()
    f.set_realtime(true)   // wall-clock animation timing: a heavy redock catches up instead of slow-motion

    // Opt-in UI tape: set EMBER_TAPE=/path to record one JSON line per frame (input + every draw
    // command + interaction events) for diagnosing live bugs with `tail -f`. Off (zero cost) otherwise.
    let tape_path = env("EMBER_TAPE")
    if tape_path.len() > 0 {
        draw.tape_on(tape_path)
    }

    // Persisted settings — defaults here, overridden by the saved store below, then applied to `f`.
    var model_idx = 0                        // 0 Opus · 1 Sonnet · 2 Haiku
    var tok_idx = 1                          // max-tokens picker: 0=1K · 1=2K · 2=4K · 3=8K (default 2K)
    var dark = true                          // theme: dark / light
    var zoom = 80                            // app-wide text size % (80% is optimal; the settings stepper drives it)
    var sys_prompt = ""                      // optional system prompt, editable in Settings; sent to the API only when non-empty
    let env_model = env("ANTHROPIC_MODEL")   // an explicit ANTHROPIC_MODEL overrides the picker
    var use_env = env_model.len() > 0
    let api_key = env("ANTHROPIC_API_KEY")
    let ready = api_key.len() > 0

    // Provider selection (the Ollama-only MVP beyond Claude): 0 = Claude (Anthropic API) · 1 = Ollama
    // (a model running locally). The chat-capable model list is DISCOVERED from the running Ollama
    // daemon (/api/tags) at launch / on switch / on refresh — only the chosen model id is persisted,
    // never the list. A local model needs no API key, so readiness is "a model is selected", not a key.
    var provider = 0
    let ollama_base = oll.default_base()     // honours $OLLAMA_HOST; the Ollama worker is spawned against this
    var ollama_models: [string] = []
    var ollama_model = ""

    let suggestions = [
        "Explain a tricky concept simply",
        "Write and explain some code",
        "Brainstorm ideas with me",
        "Draft a difficult email"
    ]

    // Multi-conversation: `convos` is the store, `active` is the open one. The active conversation's
    // transcript lives in the flat `turns: [api.Turn]` working array (mutated freely); a switch saves it
    // back into `convos[active]` and loads the target. New conversations start empty. The whole store is
    // loaded from / saved to a user-scoped JSON file (`store_path`) — chats survive a restart.
    // Load the saved store (user-scoped JSON) and rebuild [Conv]; start fresh if it's absent/empty/corrupt.
    var convos: [Conv] = []
    var active = 0
    var dock = build_workspace()     // the docked workspace; replaced below by the saved layout if present (OFI-112)
    let saved = read_file(store_path())
    if saved.len() > 0 {
        match json.parse(saved) {
            case Ok(root) {
                let carr = json.get(root, "convos")
                var ci = 0
                loop {
                    if ci == json.length(carr) {
                        break
                    }
                    let cj = json.at(carr, ci)
                    var lt: [api.Turn] = []
                    let tj = json.get(cj, "turns")
                    if !json.is_null(tj) {
                        var k = 0                                  // v3: a list of {role, text, kind?, tid?, tname?, tinput?} turns
                        loop {
                            if k == json.length(tj) {
                                break
                            }
                            let tk = json.at(tj, k)
                            var t_kind = 0                          // tool fields are absent on plain text turns
                            if !json.is_null(json.get(tk, "kind")) {
                                t_kind = json.as_int(json.get(tk, "kind"))
                            }
                            var t_tid = ""
                            if !json.is_null(json.get(tk, "tid")) {
                                t_tid = json.as_str(json.get(tk, "tid"))
                            }
                            var t_tname = ""
                            if !json.is_null(json.get(tk, "tname")) {
                                t_tname = json.as_str(json.get(tk, "tname"))
                            }
                            var t_tinput = ""
                            if !json.is_null(json.get(tk, "tinput")) {
                                t_tinput = json.as_str(json.get(tk, "tinput"))
                            }
                            lt.append(api.mk_turn_full(json.as_int(json.get(tk, "role")), json.as_str(json.get(tk, "text")), t_kind, t_tid, t_tname, t_tinput))
                            k = k + 1
                        }
                    } else {
                        let mj = json.get(cj, "msgs")              // v2 and earlier: migrate parallel msgs[]/mine[]
                        let bj = json.get(cj, "mine")
                        var k = 0
                        loop {
                            if k == json.length(mj) {
                                break
                            }
                            var rl = 1
                            if json.as_bool(json.at(bj, k)) {      // mine == true → your turn (role 0)
                                rl = 0
                            }
                            lt.append(api.mk_turn(rl, json.as_str(json.at(mj, k))))
                            k = k + 1
                        }
                    }
                    let title = title_for(lt)                          // re-derive from the turns — the STORED title may
                    convos.append(Conv { title: title, turns: lt })    // be an old 24-char-capped string ("…" baked in)
                    ci = ci + 1
                }
                active = json.as_int(json.get(root, "active"))
                if !json.is_null(json.get(root, "model")) {   // settings (absent in old v1 files → keep defaults)
                    model_idx = json.as_int(json.get(root, "model"))
                }
                if !json.is_null(json.get(root, "toks")) {
                    tok_idx = json.as_int(json.get(root, "toks"))
                }
                if !json.is_null(json.get(root, "dark")) {
                    dark = json.as_bool(json.get(root, "dark"))
                }
                if !json.is_null(json.get(root, "zoom")) {
                    zoom = json.as_int(json.get(root, "zoom"))
                }
                if !json.is_null(json.get(root, "system")) {   // system prompt (absent in pre-v4 files → stays "")
                    sys_prompt = json.as_str(json.get(root, "system"))
                }
                if !json.is_null(json.get(root, "provider")) {   // v5: the selected backend (pre-v5 → Claude)
                    provider = json.as_int(json.get(root, "provider"))
                }
                if !json.is_null(json.get(root, "ollama_model")) {
                    ollama_model = json.as_str(json.get(root, "ollama_model"))
                }
                let dockj = json.get(root, "dock")             // OFI-112: restore the saved workspace layout…
                if !json.is_null(dockj) {
                    let saved_dock = flare.dock_from_json(dockj)
                    if saved_dock.leaf_of("Chat") >= 0 {       // …only if it's intact (the pinned anchor survived)
                        dock = saved_dock
                    }
                }
            }
            case Err(e) {}
        }
    }
    if convos.len() == 0 {
        convos.append(Conv { title: "New chat", turns: [] })
        active = 0
    }
    if active >= convos.len() {
        active = convos.len() - 1
    }
    if active < 0 {
        active = 0
    }
    if model_idx < 0 || model_idx > 2 {       // guard a corrupt/old store
        model_idx = 0
    }
    if tok_idx < 0 || tok_idx > 3 {
        tok_idx = 1
    }
    if zoom < 60 || zoom > 220 {
        zoom = 80
    }
    if provider != 0 && provider != 1 {       // guard a corrupt/old store
        provider = 0
    }
    if dark {                                 // apply the restored theme + text size
        f.use_dark()
    } else {
        f.use_light()
    }
    f.set_zoom(zoom)

    if provider == 1 {                        // discover local models up front so the picker + send are ready
        ollama_models = oll.list_models(ollama_base)
        if ollama_model.len() == 0 && ollama_models.len() > 0 {
            ollama_model = ollama_models[0]
        }
    }

    // The ACTIVE conversation's transcript, copied OUT into the flat working array (mutated freely).
    var turns: [api.Turn] = convos[active].turns.clone()   // deep-copy out so the stored conversation array isn't aliased by the mutable working copy
    var input = ""                   // the composer's text
    var pending = false              // a request is in flight (gates a second send)
    var streaming = false            // currently receiving a reply's token deltas
    var cur_reply = ""               // the in-progress streamed reply (grows token by token)
    var settings_open = false        // the settings dialog (opened from the sidebar gear) is showing
    var menu_for = 0 - 1             // which conversation's "..." context-menu is open (-1 = none)
    var menu_x = 0                   // where the menu was opened (the cursor at click time)
    var menu_y = 0
    var tick = 0                     // frame counter, drives the blinking streaming caret
    var tool_pending = false         // a tool_use arrived in the current reply → execute it + continue on done
    var tp_id = ""                   // the pending call's id / name / raw JSON args
    var tp_name = ""
    var tp_input = ""

    // (The dockable workspace `dock` was created above — restored from the saved layout if present, else the
    // Conversations | Chat | Inspector default. The user drags dividers, closes ✕, re-docks and tabifies it.)

    // Async STREAMING transport: the worker fiber pumps the HTTPS stream; the render loop drains resp_ch
    // (token deltas, then a done_mark) with non-blocking try_recv, so drawing never stalls and the reply
    // grows live on screen.
    let req_ch: Channel<string> = channel(2)
    let oll_req_ch: Channel<string> = channel(2)         // Ollama's own request channel; both workers share resp_ch/stop_ch
    let resp_ch: Channel<string> = channel(64)
    let stop_ch: Channel<bool> = channel(2)
    nursery {
    spawn api.stream_worker(api_key, req_ch, resp_ch, stop_ch)
    spawn oll.stream_worker(ollama_base, oll_req_ch, resp_ch, stop_ch)   // the local-model twin; replies multiplex onto resp_ch
    var prev_down = false                              // mouse-down state last frame, to detect a release
    var dock_snap = json.stringify(dock.to_json())     // last-persisted workspace layout, to detect a change
    var coast = 12                                     // frames to keep free-running after the last activity
    var has_undo = false                               // a just-deleted conversation can be restored via the toast
    var undo_title = ""                                // ...its snapshotted title and turns, kept until the next delete
    var undo_turns: [api.Turn] = []
    loop {
        if draw.closing() {
            break
        }
        tick = tick + 1
        var dirty = false            // any persistent change this frame → write the store at frame end

        // Drain every delta that arrived since last frame (the typewriter): each appends to the live
        // reply; the done_mark commits it to the transcript.
        if pending {
            loop {
                match try_recv(resp_ch) {
                    case Some(d) {
                        if d == api.done_mark() {
                            if tool_pending {
                                // The reply ended on a tool call: commit Claude's tool_use turn (preamble + the
                                // call), run the tool, append its result, then RE-SEND — the agentic loop keeps
                                // going until a reply lands with no tool call. `pending` stays true throughout.
                                turns.append(api.mk_tool_use(cur_reply, tp_id, tp_name, tp_input))
                                let result = run_tool(tp_name, tp_input)
                                turns.append(api.mk_tool_result(tp_id, result))
                                send_turn(provider, req_ch, oll_req_ch, chosen_model(model_idx, use_env, env_model), ollama_model, tokens_for(tok_idx), sys_prompt, turns)
                                cur_reply = ""
                                tool_pending = false
                                tp_id = ""
                                tp_name = ""
                                tp_input = ""
                                streaming = false
                                dirty = true
                            } else {
                                turns.append(api.mk_turn(1, cur_reply))
                                cur_reply = ""
                                streaming = false
                                pending = false
                                dirty = true                 // reply committed → persist
                            }
                        } else if api.is_tool_msg(d) {
                            // a tool_use block finished mid-stream — unpack it; it's executed on the done_mark above
                            match json.parse(api.strip_tool_mark(d)) {
                                case Ok(v) {
                                    tp_id = json.as_str(json.get(v, "id"))
                                    tp_name = json.as_str(json.get(v, "name"))
                                    tp_input = json.as_str(json.get(v, "input"))
                                    tool_pending = true
                                }
                                case Err(e) {}
                            }
                        } else {
                            cur_reply = cur_reply + d
                            streaming = true
                        }
                        // No forced scroll here — the sticky transcript follows the bottom on its own while
                        // you're there, and leaves you alone once you scroll up to read.
                    }
                    case None {
                        break
                    }
                }
            }
        }

        var want_send = false        // a user message was added this frame → dispatch after layout
        var new_chat = false         // start a fresh conversation (button / ⌘N) — applied after layout
        var switch_to = 0 - 1        // a Recents entry was clicked → switch to it after layout (−1 = none)
        var retry_idx = 0 - 1        // a Retry button was clicked on assistant turn i → regenerate it
        var delete_conv = 0 - 1      // a Delete was chosen in a conversation menu → remove it after layout

        // Keyboard shortcuts: ⌘+ / ⌘- zoom the text, ⌘N starts a new chat.
        let cmd = key_down(KEY_SUPER_L) || key_down(KEY_SUPER_R) || key_down(KEY_CTRL_L)
        if cmd && key_pressed(KEY_EQUAL) {
            f.zoom_by(10)
            dirty = true
        }
        if cmd && key_pressed(KEY_MINUS) {
            f.zoom_by(0 - 10)
            dirty = true
        }
        if cmd && key_pressed(KEY_N) && !pending {
            new_chat = true
        }
        if key_pressed(KEY_ESCAPE) && pending {
            send(stop_ch, true)               // stop generation
        }

        draw.begin(f.bg())
        f.begin()

        // ---- body: a DOCKABLE WORKSPACE — Conversations | Chat | Inspector (std/flare DockTree). Drag a
        // divider to re-proportion, click a panel's ✕ to close it (Chat is PINNED — the anchor, no ✕), and
        // re-dock a closed side panel from the Chat toolbar. Each panel is a live Flare subtree.
        convos[active].title = title_for(turns)            // keep the active chat titled live (OFI-072)
        var hdr = "New conversation"
        if turns.len() > 0 {
            hdr = title_for(turns)
        }
        var active_model = model_label(model_idx)
        if use_env {
            active_model = "(env)"
        }
        if provider == 1 {                                 // Ollama: the active label is the local model id
            active_model = "(no model)"
            if ollama_model.len() > 0 {
                active_model = ollama_model
            }
        }

        f.dock_pin("Chat")                                 // Chat is the permanent anchor — draws no close ✕
        let dm = 12
        let dhit = f.dock_begin(dock, dm, dm, screen_width() - 2 * dm, screen_height() - 2 * dm)
        if dhit >= 0 {
            let pid = dock.close_tab(dhit)                 // a ✕ → close the active tab (leaf survives if grouped)
            f.forget(pid)
        }

        // --- Conversations: the chat list, new-chat, and settings (the old sidebar) ---
        if f.dock_panel("Conversations") {
            f.row(flare.START, flare.CENTER)               // keep "Claude" left-aligned (a bare heading centres)
            f.heading("Claude")
            f.end()
            if f.primary("+ New chat") && !pending {
                new_chat = true
            }
            // Recents: every conversation, switchable. The active one is kept titled live (set above).
            f.text_muted("Recents")
            var ci = 0
            loop {
                if ci == convos.len() {
                    break
                }
                // Skip empty conversations — a blank chat isn't "recent" yet (it's the "+ New chat" button).
                var ce = false
                if ci == active {
                    if turns.len() == 0 {
                        ce = true
                    }
                } else {
                    if convos[ci].turns.len() == 0 {
                        ce = true
                    }
                }
                if ce {
                    ci = ci + 1
                    continue
                }
                f.key("_cv{ci}")
                f.row(flare.START, flare.CENTER)
                let clicked = f.nav_item(convos[ci].title, ci == active)   // grows to fill the row; ellipsizes
                if f.ghost_button("...") {                  // per-conversation context menu (Delete)
                    menu_for = ci
                    menu_x = mouse_x()
                    menu_y = mouse_y()
                }
                f.end()
                f.key_clear()
                if clicked && !pending && ci != active {
                    switch_to = ci
                }
                ci = ci + 1
            }
            f.spacer()                       // push the settings entry to the foot of the panel
            f.row(flare.START, flare.CENTER) // wrap it: nav_item's grow=1 fills WIDTH in a row
            if f.nav_item("Settings", false) {
                settings_open = true
            }
            f.end()
            f.dock_panel_end()
        }

        // --- Chat: a toolbar (title / model / re-dock), the scrollable transcript, and the composer ---
        if f.dock_panel("Chat") {
            // Toolbar: title on the left; model + re-dock affordances pushed to the right.
            f.row(flare.START, flare.CENTER)
            f.text_muted(ellipsize(hdr, 40))
            f.spacer()
            f.text_muted("· {active_model}")
            if dock.leaf_of("Conversations") < 0 {         // closed → offer to re-dock it on the left
                if f.ghost_button("☰ Chats") {
                    let _ = dock.split_before(dock.leaf_of("Chat"), "Conversations", true, 0.26)
                }
            }
            if dock.leaf_of("Inspector") < 0 {             // closed → offer to re-dock it on the right
                if f.ghost_button("ⓘ Inspector") {
                    let _ = dock.split(dock.leaf_of("Chat"), "Inspector", true, 0.76)
                }
            }
            f.end()

            let cw = panel_cw(f, "Chat", 280, 820)         // readable page width — wraps to the Chat panel's width

            // transcript: a SCROLLABLE viewport that grows to fill the height between toolbar and composer
            f.scroll_begin_sticky("transcript")
            f.page_begin(cw)
            if turns.len() == 0 {
                f.heading("How can I help you today?")
                f.text_muted("Type below and press Enter, or pick a starting point.")
                var i = 0
                loop {
                    if i == suggestions.len() {
                        break
                    }
                    if f.button(suggestions[i]) && !pending {
                        turns.append(api.mk_turn(0, suggestions[i]))
                        want_send = true
                        f.scroll_to_bottom("transcript")
                    }
                    i = i + 1
                }
            } else {
                // VIRTUALIZE the transcript (Fix B). A cheap O(turns) pre-pass groups turns into visual BLOCKS
                // (an assistant tool_use folds its following tool_result into one card), then virtual_begin builds
                // only the blocks whose rows fall in the viewport — the rest are spacer struts. So a 500-message
                // chat renders like a 20-message one: O(total) classify, O(visible) render. The block list keeps a
                // tool_use+result as ONE item, so the window never aliases mid-pair.
                var block_start: [int] = []
                var bj = 0
                loop {
                    if bj >= turns.len() {
                        break
                    }
                    block_start.append(bj)
                    if turns[bj].kind == 1 && bj + 1 < turns.len() && turns[bj + 1].kind == 2 {
                        bj = bj + 2
                    } else {
                        bj = bj + 1
                    }
                }
                let vc = f.virtual_begin("transcript", block_start.len())
                var bk = vc.start
                loop {
                    if bk >= vc.end {
                        break
                    }
                    let i = block_start[bk]
                    f.virtual_item(bk)
                    if turns[i].kind == 1 {
                        // assistant tool_use: render any spoken preamble, then the tool card. Fold a matching
                        // tool_result into the card (so it isn't drawn as you).
                        if turns[i].text.len() > 0 {
                            let _ = claude_turn(f, turns[i].text, cw, "pre{i}", false)
                        }
                        var have_result = false
                        if i + 1 < turns.len() {
                            if turns[i + 1].kind == 2 {
                                have_result = true
                            }
                        }
                        if have_result {
                            tool_card(f, "tc{i}", turns[i].tool_name, turns[i].tool_input, turns[i + 1].text, true, cw)
                        } else {
                            tool_card(f, "tc{i}", turns[i].tool_name, turns[i].tool_input, "", false, cw)
                        }
                    } else if turns[i].kind == 2 {
                        tool_card(f, "tc{i}", "result", "", turns[i].text, true, cw)   // orphan result (defensive)
                    } else if turns[i].role == 0 {
                        let ue = f.enter("uent{i}")            // your message fades + springs up into place
                        f.fade_begin(ue)
                        f.at(0.0, (1.0 - ue) * 18.0)
                        user_turn(f, turns[i].text, cw)        // your turn → a rounded chat bubble
                        f.end_at()
                        f.fade_end()
                    } else {
                        if claude_turn(f, turns[i].text, cw, "msg{i}", true) {
                            retry_idx = i                // Retry → regenerate this turn after layout
                        }
                    }
                    f.virtual_item_end()
                    bk = bk + 1
                }
                f.virtual_end()
                if streaming {
                    var caret = ""                       // a blinking caret marks the live, growing reply
                    if (tick / 20) % 2 == 0 {
                        caret = " ▌"
                    }
                    let _ = claude_turn(f, cur_reply + caret, cw, "stream", false)
                } else if pending {
                    thinking_turn(f, tick)               // waiting for the first delta (animated spinner)
                }
            }
            f.page_end()
            f.scroll_end("transcript")
            if f.scroll_fab("transcript") {           // a "jump to latest" button appears when scrolled up
                f.scroll_to_bottom("transcript")
            }

            // composer: Enter sends. While a reply streams, a Stop button (or Esc) cancels it. Centred to match.
            f.page_begin(cw)
            if pending {
                f.row(flare.START, flare.CENTER)
                if f.primary("■  Stop") {
                    send(stop_ch, true)
                }
                f.end()
            } else {
                input = f.text_area("composer", input)   // multi-line: Shift+Enter = newline, Enter = send
                if f.submit() {
                    if input.len() > 0 {
                        turns.append(api.mk_turn(0, input))
                        want_send = true
                        f.scroll_to_bottom("transcript")
                    }
                    input = ""
                }
            }
            f.page_end()
            f.dock_panel_end()
        }

        // --- Inspector: the conversation's context at a glance, plus quick layout/settings actions ---
        if f.dock_panel("Inspector") {
            let iw = panel_cw(f, "Inspector", 120, 600)
            f.heading("Context")
            f.divider()
            f.text_muted("Provider")
            f.label(provider_label(provider))
            f.text_muted("Model")
            f.label(active_model)
            f.text_muted("Max tokens")
            let mt = tokens_for(tok_idx)
            f.label("{mt}")
            f.text_muted("Messages")
            // Count user/assistant messages and tool calls in the live transcript.
            var nmsg = 0
            var ntool = 0
            var ii = 0
            loop {
                if ii == turns.len() {
                    break
                }
                if turns[ii].kind == 1 {
                    ntool = ntool + 1
                } else if turns[ii].kind == 0 {
                    nmsg = nmsg + 1
                }
                ii = ii + 1
            }
            f.label("{nmsg} message(s) · {ntool} tool call(s)")
            f.text_muted("System prompt")
            if sys_prompt.len() > 0 {
                f.paragraph(sys_prompt, iw)
            } else {
                f.label("(none — set in Settings)")
            }
            f.text_muted("Tools")
            if provider == 1 {
                f.label("(none — local model)")
            } else {
                f.label("read_file · write_file")
            }
            f.spacer()
            f.divider()
            f.row(flare.START, flare.CENTER)
            if f.ghost_button("Settings") {
                settings_open = true
            }
            if f.ghost_button("Reset layout") {
                dock = build_workspace()
            }
            f.end()
            f.dock_panel_end()
        }

        // ---- conversation context-menu: a Flare popover anchored at the cursor (the "..." opens it).
        // A press outside dismisses it; Delete removes that conversation (applied after layout). ----
        if menu_for >= 0 {
            if !f.popover_begin("convmenu", menu_x, menu_y) {
                menu_for = 0 - 1
            }
            if f.menu_item("Delete chat") {
                delete_conv = menu_for
                menu_for = 0 - 1
            }
            f.popover_end()
        }

        // ---- settings dialog: a Flare modal (a centred panel over a dimmed scrim). The sidebar gear
        // opens it; a click on the scrim, or Done, closes it. Built last so it layers above the app. ----
        if settings_open {
            if !f.modal_begin("settings", 460, 0) {
                settings_open = false              // a press on the scrim dismisses it
            }
            f.heading("Settings")
            f.divider()

            f.text_muted("Appearance")
            var appear = 0
            if !dark {
                appear = 1
            }
            let new_appear = f.segmented("appearance", ["Dark", "Light"], appear)
            if new_appear != appear {
                dark = (new_appear == 0)
                if dark {
                    f.use_dark()
                } else {
                    f.use_light()
                }
                dirty = true
            }

            f.text_muted("Provider")
            let np = f.segmented("provider", ["Claude (API)", "Ollama (local)"], provider)
            if np != provider {
                provider = np
                dirty = true
                if provider == 1 {                          // switched to local → discover installed chat models now
                    ollama_models = oll.list_models(ollama_base)
                    if ollama_model.len() == 0 && ollama_models.len() > 0 {
                        ollama_model = ollama_models[0]
                    }
                }
            }

            if provider == 1 {
                // Ollama: choose from the chat models installed on THIS machine (discovered from the daemon).
                f.text_muted("Local model")
                if ollama_models.len() == 0 {
                    f.label("No models found — run `ollama serve` and `ollama pull <model>`.")
                } else {
                    var mi = 0
                    loop {
                        if mi == ollama_models.len() {
                            break
                        }
                        f.key("om{mi}")
                        if f.nav_item(ollama_models[mi], ollama_models[mi] == ollama_model) {
                            ollama_model = ollama_models[mi]
                            dirty = true
                        }
                        f.key_clear()
                        mi = mi + 1
                    }
                }
                if f.ghost_button("Refresh models") {
                    ollama_models = oll.list_models(ollama_base)
                    if ollama_model.len() == 0 && ollama_models.len() > 0 {
                        ollama_model = ollama_models[0]
                    }
                }
            } else {
                f.text_muted("Model")
                if use_env {
                    f.text_muted("Pinned by ANTHROPIC_MODEL")
                } else {
                    let nm = f.segmented("model", ["Opus 4.8", "Sonnet 4.6", "Haiku 4.5"], model_idx)
                    if nm != model_idx {
                        model_idx = nm
                        dirty = true
                    }
                }
            }

            f.text_muted("Max tokens")
            let nt = f.segmented("toks", ["1K", "2K", "4K", "8K"], tok_idx)
            if nt != tok_idx {
                tok_idx = nt
                dirty = true
            }

            f.text_muted("System prompt")
            let new_sys = f.text_area("sysprompt", sys_prompt)
            if new_sys != sys_prompt {                  // typed into the system field → persist it
                sys_prompt = new_sys
                dirty = true
            }
            // drain a stray Enter (in the system field Shift+Enter inserts a newline) so it can't trip the
            // composer's send on the next frame, then carry on building the dialog.
            let _ = f.submit()

            f.text_muted("Text size")
            f.row(flare.START, flare.CENTER)
            if f.button("Smaller") {
                f.zoom_by(0 - 10)
                dirty = true
            }
            f.label("{f.zoom}%")
            if f.button("Larger") {
                f.zoom_by(10)
                dirty = true
            }
            f.end()

            f.divider()
            f.row(flare.END, flare.CENTER)
            if f.primary("Done") {
                settings_open = false
            }
            f.end()
            f.modal_end()
        }

        f.finish()
        f.toast_layer()    // draw + age any toasts (e.g. "Copied to clipboard") above the UI, after finish()

        // Undo a delete: the "Conversation deleted · Undo" toast fires "undo_del" when its button is clicked.
        if has_undo && f.take_action() == "undo_del" {
            convos.append(Conv { title: undo_title, turns: undo_turns.clone() })   // re-insert the snapshot...
            switch_to = convos.len() - 1                                    // ...and jump back to it (loaded post-finish)
            has_undo = false
            dirty = true
            f.toast("Conversation restored")
        }

        // Idle frame-gating: when nothing is moving — no input, no animation in flight, no reply streaming —
        // let EndDrawing block on OS events instead of re-rendering 60 identical frames/second (the immediate-
        // mode CPU burn). A short coast keeps the loop free-running just after activity so a settling spring or
        // the send queued just below (pending flips true next frame) is never cut off; any input/anim/stream
        // re-arms it. had_input() covers mouse AND keyboard, so every shortcut-driven action stays awake too.
        if had_input() || f.is_animating() || pending {
            coast = 12
        } else if coast > 0 {
            coast = coast - 1
        }
        set_event_waiting(coast == 0)
        draw.finish()

        // Dispatch the turn AFTER the frame is built (so `turns` already holds the new user message).
        if want_send {
            dirty = true
            let can_send = (provider == 1 && ollama_model.len() > 0) || (provider == 0 && ready)
            if can_send {
                send_turn(provider, req_ch, oll_req_ch, chosen_model(model_idx, use_env, env_model), ollama_model, tokens_for(tok_idx), sys_prompt, turns)
                pending = true
            } else if provider == 1 {
                turns.append(api.mk_turn(1, "No local model selected. Start `ollama serve`, pull a model (e.g. `ollama pull llama3.2`), then choose it in Settings → Provider → Ollama."))
                f.scroll_to_bottom("transcript")
            } else {
                turns.append(api.mk_turn(1, "No API key visible to the app. Make sure ANTHROPIC_API_KEY is EXPORTED in the shell you launch from (export it, not just set it), then relaunch."))
                f.scroll_to_bottom("transcript")
            }
        }

        // Apply a New chat / Recents switch AFTER the frame — the checkout pattern (OFI-072): save the
        // working arrays we just rendered back into the active Conv (whole-array write-back through the
        // index persists; .append through an index would not), then load the target. Skip if we just
        // dispatched a turn this frame (can't switch and send at once).
        if new_chat && !want_send && turns.len() > 0 {
            dirty = true
            convos[active].title = title_for(turns)   // title first — the move below consumes turns
            convos[active].turns = turns                    // whole-array write-back (persists; OFI-072)
            convos.append(Conv { title: "New chat", turns: [] })
            active = convos.len() - 1
            turns = []
            input = ""
            cur_reply = ""
            streaming = false
        }
        if switch_to >= 0 && !want_send {
            dirty = true
            convos[active].title = title_for(turns)
            convos[active].turns = turns
            active = switch_to
            turns = convos[active].turns.clone()                              // deep-copy OUT into the mutable working array
            input = ""
            cur_reply = ""
            streaming = false
        }

        // Retry: regenerate assistant turn `retry_idx` — drop it (and anything after) and re-send the
        // conversation, which now ends at the user message that prompted it. (idx ≥ 1: a user turn precedes it.)
        if retry_idx >= 1 && !want_send && !pending {
            dirty = true
            turns = turns.slice(0, retry_idx)
            let can_retry = (provider == 1 && ollama_model.len() > 0) || (provider == 0 && ready)
            if can_retry {
                send_turn(provider, req_ch, oll_req_ch, chosen_model(model_idx, use_env, env_model), ollama_model, tokens_for(tok_idx), sys_prompt, turns)
                pending = true
            }
            f.scroll_to_bottom("transcript")
        }

        // Delete: remove conversation `delete_conv`. Write the live working arrays back first (so the active
        // transcript isn't lost), drop that one conversation (remove_at shifts the rest down — no rebuild,
        // no deep-clone of every other conversation), fix `active`, then reload the working arrays from the
        // new active conversation (a fresh empty chat if we deleted the last one).
        if delete_conv >= 0 && !want_send {
            dirty = true
            convos[active].title = title_for(turns)
            convos[active].turns = turns
            undo_title = convos[delete_conv].title           // snapshot the doomed conversation so Undo can restore it
            undo_turns = convos[delete_conv].turns.clone()   // clone — the turns can't be moved out of the conv field
            has_undo = true
            f.toast_action("Conversation deleted", "Undo", "undo_del")
            convos.remove_at(delete_conv)                    // O(n) shift; the removed Conv (+ its turns) is dropped
            if delete_conv < active {
                active = active - 1
            }
            if convos.len() == 0 {
                convos.append(Conv { title: "New chat", turns: [] })
                active = 0
            }
            if active >= convos.len() {
                active = convos.len() - 1
            }
            if active < 0 {
                active = 0
            }
            turns = convos[active].turns.clone()             // deep-copy OUT into the mutable working array
            input = ""
            cur_reply = ""
            streaming = false
        }

        // A dock change (resize / close / re-dock / tabify / tab-switch — all done inside dock_begin) is
        // detected on mouse RELEASE by comparing the workspace's serialised layout to the last saved one, so
        // the rearranged workspace persists too (OFI-112) without re-serialising it every frame.
        let now_down = f.ui.down
        if prev_down && !now_down {
            let cur_dock = json.stringify(dock.to_json())
            if cur_dock != dock_snap {
                dirty = true
                dock_snap = cur_dock
            }
        }
        prev_down = now_down

        // Persist the store at frame end if anything changed (a send, a committed reply, new/switch/delete/retry).
        if dirty {
            save_store(convos, active, turns, model_idx, tok_idx, dark, f.zoom, sys_prompt, dock, provider, ollama_model)
        }
    }
    close(req_ch)        // wake the Claude worker out of recv → it returns None and exits
    close(oll_req_ch)    // …and the Ollama worker likewise
    // M:N safety: tear graphics down on THIS thread (worker 0 — it owns the GL context + the Cocoa
    // main loop) BEFORE the nursery join below. The join parks the main fiber, and under the M:N
    // scheduler it can RESUME on a different worker thread — but raylib/OpenGL teardown (glDeleteTextures
    // via UnloadFont) MUST run on the GL-context thread or it segfaults. The 1:1 build pins main anyway.
    if tape_path.len() > 0 {
        draw.tape_off()
    }
    draw.close()
    }                    // nursery: joins both fetch workers here
    return 0
}
