//! LLM HTML generation — streaming API bridge
//!
//! Calls an LLM's chat API with stream:true, accumulates the HTML fragments
//! from each token, and returns the complete HTML string to JS.
//!
//! Currently supported:
//!   "ollama"  — NDJSON, one JSON object per \n, no SSE envelope
//!               content path: .message.content
//!               default base_url: http://localhost:11434
//!
//! JS usage:
//!   const html = await zxp.llmHTML({
//!     provider: "ollama",    // optional, default "ollama"
//!     model:    "llama3.2",
//!     prompt:   "a dashboard with 3 metric cards",
//!     system:   "...",       // optional, has a sensible default
//!     base_url: "http://...", // optional
//!   });
//!   document.querySelector('#container').innerHTML = html;

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const curl = @import("curl");
const c = curl.libcurl;

const default_system =
    "You are a UI generator. Output ONLY raw HTML — no markdown, no code fences, no backticks, no explanation. " ++
    "Start your response directly with an HTML tag. " ++
    "Use ONLY inline styles with these properties: display:flex, flex-direction, justify-content, align-items, gap, " ++
    "padding, margin, color, background, font-size, font-weight, border-radius, width, height. " ++
    "No external fonts. No CSS variables. No animations. No <script> tags.";

// ---------------------------------------------------------------------------
// Ollama streaming state
// ---------------------------------------------------------------------------

const OllamaState = struct {
    allocator: std.mem.Allocator,
    /// Accumulates bytes until a complete \n-terminated line is available.
    line_buffer: std.ArrayList(u8) = .empty,
    /// Collects all HTML content fragments across tokens.
    html_buffer: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
};

/// Typed struct for parseFromSlice — only the fields we care about.
const OllamaChunk = struct {
    message: struct {
        content: []const u8 = "",
    } = .{},
    done: bool = false,
};

fn ollamaWriteCb(
    ptr: [*c]u8,
    size: usize,
    nmemb: usize,
    ud: ?*anyopaque,
) callconv(.c) usize {
    const total = size * nmemb;
    const state: *OllamaState = @ptrCast(@alignCast(ud.?));
    if (state.err != null) return 0;

    state.line_buffer.appendSlice(state.allocator, ptr[0..total]) catch |e| {
        state.err = e;
        return 0;
    };

    // Walk through complete \n-terminated lines without shifting the buffer each time.
    // cursor advances past each newline; a single replaceRange removes all processed
    // lines at the end — O(1) memmoves instead of O(N).
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, state.line_buffer.items, cursor, '\n')) |nl| {
        const line = state.line_buffer.items[cursor..nl];
        cursor = nl + 1;

        if (line.len == 0) continue;

        // Fixed 16 KB stack buffer: enough for any Ollama token line.
        // parseFromSliceLeaky returns T directly (no Parsed wrapper / no deinit needed).
        // content may point into `line` (no escapes) or into fba (escaped chars like \u003c).
        // Both stay valid until appendSlice copies the bytes — which happens before
        // we touch line_buffer below.
        var buf: [16384]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);

        if (std.json.parseFromSliceLeaky(
            OllamaChunk,
            fba.allocator(),
            line,
            .{ .ignore_unknown_fields = true },
        )) |chunk| {
            if (chunk.message.content.len > 0) {
                state.html_buffer.appendSlice(state.allocator, chunk.message.content) catch |e| {
                    state.err = e;
                    // Drain the lines we already processed before aborting.
                    state.line_buffer.replaceRange(state.allocator, 0, cursor, &.{}) catch {};
                    return 0;
                };
            }
        } else |_| {} // malformed line → skip silently
    }

    // Remove all processed lines in one shot.
    if (cursor > 0) {
        state.line_buffer.replaceRange(state.allocator, 0, cursor, &.{}) catch |e| {
            state.err = e;
            return 0;
        };
    }

    return total;
}

// ---------------------------------------------------------------------------
// streamFromOllama — main Zig function
// ---------------------------------------------------------------------------

/// POST to Ollama /api/chat with stream:true.
/// Returns the accumulated HTML as an owned slice (caller must free).
pub fn streamFromOllama(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    model: []const u8,
    system: []const u8,
    prompt: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var state = OllamaState{ .allocator = alloc };
    defer state.line_buffer.deinit(alloc);
    // on error, free; on success, transfer ownership via toOwnedSlice
    errdefer state.html_buffer.deinit(alloc);

    // Build the JSON body — std.json.Stringify handles all escaping.
    const body_value = .{
        .model = model,
        .messages = [_]struct { role: []const u8, content: []const u8 }{
            .{ .role = "system", .content = system },
            .{ .role = "user", .content = prompt },
        },
        .stream = true,
    };
    var body_out: std.Io.Writer.Allocating = .init(aa);
    try std.json.Stringify.value(body_value, .{}, &body_out.writer);
    const body = body_out.written();
    const body_z = try aa.dupeZ(u8, body);

    const endpoint = try std.fmt.allocPrint(aa, "{s}/api/chat", .{base_url});
    const endpoint_z = try aa.dupeZ(u8, endpoint);

    const ca_bundle = try curl.allocCABundle(aa);
    defer ca_bundle.deinit();

    var easy = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
    defer easy.deinit();

    try easy.setUrl(endpoint_z);
    z.hardenEasy(easy);
    // LLM generation can take longer than the standard 30s timeout.
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_TIMEOUT_MS, @as(c_long, 300_000));

    // POST with JSON body
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_POST, @as(c_long, 1));
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_POSTFIELDS, body_z.ptr);
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));

    var headers: ?*c.curl_slist = null;
    headers = c.curl_slist_append(headers, "Content-Type: application/json");
    defer c.curl_slist_free_all(headers);
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_HTTPHEADER, headers);

    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEFUNCTION, ollamaWriteCb);
    _ = c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEDATA, &state);

    const ret = try easy.perform();
    if (state.err) |e| return e;
    if (ret.status_code < 200 or ret.status_code >= 300) return error.HttpError;

    return state.html_buffer.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Helper: extract a string field from a JS object into an arena
// ---------------------------------------------------------------------------

fn extractStr(
    ctx: zqjs.Context,
    obj: qjs.JSValue,
    key: [*:0]const u8,
    alloc: std.mem.Allocator,
) ?[]u8 {
    const val = ctx.getPropertyStr(obj, key);
    defer ctx.freeValue(val);
    if (!ctx.isString(val)) return null;
    const zs = ctx.toZString(val) catch return null;
    defer ctx.freeZString(zs);
    return alloc.dupe(u8, zs) catch null;
}

// ---------------------------------------------------------------------------
// JS binding: __native_llmHTML(config) → string
// ---------------------------------------------------------------------------

pub fn js_native_llmHTML(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);
    const alloc = rc.allocator;

    if (argc < 1 or !ctx.isObject(argv[0]))
        return qjs.JS_ThrowTypeError(ctx.ptr, "llmHTML requires a config object");

    // Use an arena for all extracted strings — freed at end of function.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const cfg = argv[0];
    const provider = extractStr(ctx, cfg, "provider", aa) orelse aa.dupe(u8, "ollama") catch return zqjs.EXCEPTION;
    const model = extractStr(ctx, cfg, "model", aa) orelse
        return qjs.JS_ThrowTypeError(ctx.ptr, "llmHTML: model is required");
    const prompt = extractStr(ctx, cfg, "prompt", aa) orelse
        return qjs.JS_ThrowTypeError(ctx.ptr, "llmHTML: prompt is required");
    const system = extractStr(ctx, cfg, "system", aa) orelse
        aa.dupe(u8, default_system) catch return zqjs.EXCEPTION;
    const base_url = extractStr(ctx, cfg, "base_url", aa) orelse
        aa.dupe(u8, "http://localhost:11434") catch return zqjs.EXCEPTION;

    if (!std.mem.eql(u8, provider, "ollama"))
        return qjs.JS_ThrowTypeError(ctx.ptr, "llmHTML: only 'ollama' is supported so far");

    const html = streamFromOllama(alloc, base_url, model, system, prompt) catch |e|
        return qjs.JS_ThrowInternalError(ctx.ptr, "llmHTML failed: %s", @errorName(e).ptr);
    defer alloc.free(html);

    return ctx.newString(html);
}
