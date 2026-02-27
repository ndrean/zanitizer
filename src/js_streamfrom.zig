//! zxp.streamFrom(url) — curl → lexbor streaming bridge
//!
//! Fetches a URL via curl and feeds the response bytes directly to the
//! lexbor streaming parser (beginStream / processStreamChunk / endStream),
//! without buffering the entire response in memory first.
//!
//! Useful for:
//!   - LLM-generated HTML (token-by-token, slow trickle)
//!   - Large SSR payloads where buffering wastes memory
//!   - Any source that benefits from incremental DOM construction
//!
//! For normal web pages (fast servers, small-ish HTML) `zxp.goto` is simpler.

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const curl = @import("curl");
const c = curl.libcurl;

// ---------------------------------------------------------------------------
// Curl write callback context
// ---------------------------------------------------------------------------

const StreamCtx = struct {
    engine: *z.ScriptEngine,
    err: ?anyerror = null,
};

fn writeCb(
    ptr: [*c]u8,
    size: usize,
    nmemb: usize,
    ud: ?*anyopaque,
) callconv(.c) usize {
    const total = size * nmemb;
    const ctx: *StreamCtx = @ptrCast(@alignCast(ud.?));
    if (ctx.err != null) return 0; // signal abort to curl
    ctx.engine.processStreamChunk(ptr[0..total]) catch |e| {
        ctx.err = e;
        return 0; // returning 0 triggers CURLE_WRITE_ERROR, aborting the transfer
    };
    return total;
}

// ---------------------------------------------------------------------------
// Core implementation — shared by JS binding and renderProxyHandler
// ---------------------------------------------------------------------------

/// Fetch `url` with curl and stream the response body directly into the
/// engine's lexbor document.  Calls beginStream → writeCb (per chunk) →
/// endStream.  The engine must not already have an active stream.
pub fn streamFromUrl(engine: *z.ScriptEngine, url: []const u8) !void {
    const alloc = engine.allocator;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const opts: z.LoadPageOptions = .{
        .base_dir = url, // URL as base dir — same convention as zxp.goto
        .load_stylesheets = true,
        .execute_scripts = true,
    };

    try engine.beginStream(opts);
    errdefer engine.streaming_active = false; // reset flag if curl fails mid-stream

    const ca_bundle = try curl.allocCABundle(aa);
    defer ca_bundle.deinit();

    var easy = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
    defer easy.deinit();

    const url_z = try aa.dupeZ(u8, url);
    try easy.setUrl(url_z);
    z.hardenEasy(easy);

    // Override the writer with our streaming callback.
    // hardenEasy already set timeouts/limits on easy.handle; this just
    // swaps the data destination from Allocating→writer to our callback.
    // StreamCtx must be stack-stable for the duration of perform().
    var stream_ctx = StreamCtx{ .engine = engine };
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEFUNCTION, writeCb);
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEDATA, &stream_ctx);

    const ret = try easy.perform();
    if (stream_ctx.err) |e| return e;
    if (ret.status_code < 200 or ret.status_code >= 300) return error.HttpError;

    try engine.endStream(opts);
}

// ---------------------------------------------------------------------------
// JS binding: __native_streamFrom(url)
// ---------------------------------------------------------------------------

pub fn js_native_streamFrom(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);

    const engine_ptr = rc.engine_ptr orelse
        return qjs.JS_ThrowInternalError(ctx.ptr, "streamFrom: no active engine");
    const engine: *z.ScriptEngine = @ptrCast(@alignCast(engine_ptr));

    if (argc < 1) return qjs.JS_ThrowTypeError(ctx.ptr, "streamFrom requires a URL string");

    const url_str = ctx.toZString(argv[0]) catch
        return qjs.JS_ThrowTypeError(ctx.ptr, "streamFrom: url must be a string");
    defer ctx.freeZString(url_str);

    streamFromUrl(engine, url_str) catch |e|
        return qjs.JS_ThrowInternalError(ctx.ptr, "streamFrom failed: %s", @errorName(e).ptr);

    return zqjs.UNDEFINED;
}
