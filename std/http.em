// std/http — HTTP(S) transport over Ember's FFI (libcurl). Two shapes share one binding:
//   • post(url, headers, body) -> string : a blocking request, the whole response body at once.
//   • a streaming PULL : open() POSTs and hands back an opaque handle; next() yields body chunks
//     as the network delivers them ("" once the transfer ends); status() is the HTTP code; close()
//     frees the handle. The handle is a linear `Ptr`, so the compiler makes you close it exactly
//     once, on every path. Pair the stream with std/sse to decode SSE events as they arrive (e.g.
//     an LLM's token-by-token deltas). Design of record: docs/http-design.md.
//
// Only links under the networking build (`make net` / `make net-graphics`); a default-build
// program that imports this fails to link, exactly as std/ui needs the graphics build.
//
//   import "std/http" as http
//   let body = http.post("https://example.com", "", "")
//
//   let h = http.open(url, headers, req)            // streaming
//   loop {
//       let chunk = http.next(h)
//       if chunk.len() == 0 { break }
//       // … feed chunk to a std/sse decoder …
//   }
//   let _ = http.close(h)

// The C bindings (libcurl, registered in src/cextern.c). Callers use the wrappers below, which
// give the module a clean, stutter-free API (http.post, not http.http_post).
extern "c" {
    fn http_post(url: string, headers: string, body: string) -> string
    fn http_open(url: string, headers: string, body: string) -> Ptr
    fn http_next(h: Ptr) -> string
    fn http_status(h: Ptr) -> i64
    fn http_close(move h: Ptr) -> i64
}


// post sends one request and returns the entire response body as a string (blocking). `headers`
// is one string of header lines separated by "\n"; an empty body sends an empty POST.
fn post(url: string, headers: string, body: string) -> string {
    return http_post(url, headers, body)
}


// open starts a streaming POST and returns the transfer handle. Pump it with next() until that
// returns "", then close() it. The handle is a linear resource — close it on every path.
fn open(url: string, headers: string, body: string) -> Ptr {
    return http_open(url, headers, body)
}


// next pumps the transfer and returns the next body chunk as it arrives, or "" when the response
// has fully arrived (the loop-terminating sentinel).
fn next(h: Ptr) -> string {
    return http_next(h)
}


// status is the HTTP response status code (0 until the response headers have arrived).
fn status(h: Ptr) -> i64 {
    return http_status(h)
}


// close frees the transfer handle, consuming it so it can never be used again. Returns libcurl's
// result code. Call exactly once per open() — the compiler enforces it.
fn close(move h: Ptr) -> i64 {
    return http_close(h)
}
