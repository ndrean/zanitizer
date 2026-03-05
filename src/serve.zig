const std = @import("std");
const z = @import("root.zig");
const httpz = z.httpz;
const zxp_runtime = z.zxp_runtime;
const js_streamfrom = z.js_streamfrom;
const js_llm = z.js_llm;
const mcp = z.mcp;

const WriterContext = struct {
    res: *httpz.Response,
    is_sse: bool,
};

/// Set by dispatch() so runHandler() can format its final result correctly.
threadlocal var tl_is_sse: bool = false;

pub const Handler = struct {
    app_ctx: *AppContext,
    pub fn dispatch(self: *Handler, action: httpz.Action(*AppContext), req: *httpz.Request, res: *httpz.Response) !void {
        // CORS — allow browser pages on any origin to call the local dev server.
        res.header("Access-Control-Allow-Origin", "*");
        res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        res.header("Access-Control-Allow-Headers", "Content-Type");

        // Preflight: browsers send OPTIONS before cross-origin POST/PUT/PATCH.
        // Return 200 immediately so the actual request is allowed.
        if (req.method == .OPTIONS) {
            res.status = 200;
            return;
        }

        var is_sse = false;

        // /mcp uses JSON-RPC; mcp-remote sends "Accept: application/json, text/event-stream"
        // but expects a plain JSON response, not an SSE stream. Skip SSE injection for it.
        const is_mcp = std.mem.startsWith(u8, req.url.path, "/mcp");
        if (!is_mcp) {
            if (req.header("accept")) |accept| {
                if (std.mem.indexOf(u8, accept, "text/event-stream") != null) {
                    is_sse = true;
                    res.header("Content-Type", "text/event-stream");
                    res.header("Cache-Control", "no-cache");
                    res.header("Connection", "keep-alive");
                }
            }
        }

        tl_is_sse = is_sse;
        defer tl_is_sse = false;

        // Execute the specific route handler (e.g., runHandler)
        try action(self.app_ctx, req, res);
    }
};

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    sandbox_root: []const u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !AppContext {
        const sandbox_root = try std.fs.cwd().realpathAlloc(allocator, root);
        return AppContext{ .allocator = allocator, .sandbox_root = sandbox_root };
    }

    pub fn deinit(self: *AppContext) void {
        self.allocator.free(self.sandbox_root);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    app_ctx: *AppContext, // heap-allocated so the Handler pointer stays valid
    server: httpz.Server(*Handler),

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Server {
        const config = httpz.Config{
            .address = .localhost(9984),
            .thread_pool = .{ .count = 32, .buffer_size = 131_072, .backlog = 2_000 },
            .workers = .{ .count = 2, .large_buffer_count = 32, .large_buffer_size = 131_072 },
        };

        // Heap-allocate so the pointer we hand to Handler stays valid after init() returns.
        const app_ctx = try allocator.create(AppContext);
        errdefer allocator.destroy(app_ctx);
        app_ctx.* = try AppContext.init(allocator, root);
        errdefer app_ctx.deinit();

        var handler = Handler{ .app_ctx = app_ctx };

        var server = try httpz.Server(*Handler).init(
            allocator,
            config,
            &handler,
        );

        var router = try server.router(.{});
        router.get("/health", healthHandler, .{});
        router.post("/run", runHandler, .{});
        router.post("/stream", streamHandler, .{});
        router.post("/render", renderProxyHandler, .{});
        router.get("/render_llm", renderLlmHandler, .{});
        router.post("/render_llm", renderLlmPostHandler, .{});
        router.post("/mcp", mcp.mcpHandler, .{});
        // GET /mcp — Streamable HTTP 2025-03-26: mcp-remote opens a GET SSE
        // channel for server→client events. We don't push events, so return 405
        // so mcp-remote falls back to request-response mode immediately.
        router.get("/mcp", mcp.mcpGetHandler, .{});
        // OPTIONS preflight — dispatch() adds the CORS headers; these just ensure
        // the route is matched so dispatch is actually called.
        router.options("/render_llm", corsPreflightHandler, .{});
        router.options("/run", corsPreflightHandler, .{});
        router.options("/mcp", corsPreflightHandler, .{});

        return Server{ .allocator = allocator, .app_ctx = app_ctx, .server = server };
    }

    /// Blocks until stop() is called from the signal handler.
    pub fn listen(self: *Server) !void {
        try self.server.listen();
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit();
        self.app_ctx.deinit();
        self.allocator.destroy(self.app_ctx);
    }
};

// const McpRequest = struct {
//     jsonpc: []const u8,
//     id: ?std.json.Value,
//     method: []const u8,
//     params: ?std.json.Value = null,
// };

// pub fn mcpHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
//     const body = req.body() orelse {};
// }

pub fn healthHandler(_: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
}

/// OPTIONS preflight — dispatch() already added the CORS headers; just return 204.
pub fn corsPreflightHandler(_: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 204;
}

/// Detect MIME type from the first few magic bytes of a binary buffer.
fn sniffMime(bytes: []const u8) []const u8 {
    if (bytes.len >= 4) {
        if (std.mem.startsWith(u8, bytes, "\x89PNG")) return "image/png";
        if (std.mem.startsWith(u8, bytes, "\xFF\xD8")) return "image/jpeg";
        if (std.mem.startsWith(u8, bytes, "%PDF")) return "application/pdf";
        if (std.mem.startsWith(u8, bytes, "GIF8")) return "image/gif";
        if (std.mem.startsWith(u8, bytes, "RIFF") and bytes.len >= 12 and
            std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    }
    return "application/octet-stream";
}

// Bridges zxp.write(str) → res.chunk(str) for streaming output.
// Called from the thread-local set in runHandler.
fn chunkWriter(ptr: *anyopaque, data: []const u8) void {
    const ctx: *WriterContext = @ptrCast(@alignCast(ptr));
    if (ctx.is_sse) {
        ctx.res.chunk("data: ") catch {};
        ctx.res.chunk(data) catch {};
        ctx.res.chunk("\n\n") catch {};
    } else {
        ctx.res.chunk(data) catch {};
    }
}

pub fn runHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing body: expected a JS script";
        return;
    };

    const alloc = app_ctx.allocator;

    // Reuse (or lazily create) the thread-local ZxpRuntime — amortises the
    // ~2.5 MB JS_NewRuntime2 cost across all requests on this worker thread.
    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    // Hook console.log / zxp.write to the HTTP response — placed AFTER engine init
    // so the zexplorer.js boot log does not pollute the response body.
    var rh_writer_ctx = WriterContext{ .res = res, .is_sse = tl_is_sse };
    z.js_console.setChunkWriter(chunkWriter, &rh_writer_ctx);
    defer z.js_console.clearChunkWriter();

    // Set up zxp.write + zxp.flags + zxp.args, mirroring runCliRequest in main.zig.
    {
        const scope = z.wrapper.Context.GlobalScope.init(engine.ctx);
        defer scope.deinit();
        const zxp_obj = engine.ctx.getPropertyStr(scope.global, "zxp");
        defer engine.ctx.freeValue(zxp_obj);

        const write_fn = engine.ctx.newCFunction(z.js_console.js_stdout_write, "write", 1);
        _ = try engine.ctx.setPropertyStr(zxp_obj, "write", write_fn);
        _ = try engine.ctx.setPropertyStr(zxp_obj, "args", engine.ctx.newArray());
        _ = try engine.ctx.setPropertyStr(zxp_obj, "flags", engine.ctx.newObject());
    }

    // Evaluate — keep the raw JS value so we can inspect its type.
    const val = try engine.evalAsync(body, "<serve>");
    defer engine.ctx.freeValue(val);

    // Drain remaining timers/callbacks after the top-level Promise settles.
    // evalAsync exits as soon as the Promise is no longer Pending, but
    // setInterval/setTimeout callbacks registered during script execution
    // haven't fired yet. engine.run() continues until all pending work is
    // exhausted (or the 30s deadline). If nothing is pending, it exits
    // immediately — safe to always call.
    try engine.run();

    // ── Binary (ArrayBuffer) ─────────────────────────────────────────────────
    // Script returned raw bytes (e.g. PNG from zxp.paintDOM).
    // Sniff the MIME type from magic bytes and send as a binary body.
    // Bytes are copied into the response arena so they survive engine.deinit().
    if (engine.ctx.isArrayBuffer(val)) {
        const bytes = try engine.ctx.getArrayBuffer(val);
        res.header("Content-Type", sniffMime(bytes));
        res.body = try res.arena.dupe(u8, bytes);
        return;
    }

    // ── Empty (undefined / null) ─────────────────────────────────────────────
    // Script used zxp.write() for streaming output — nothing left to send.
    if (engine.ctx.isUndefined(val) or engine.ctx.isNull(val)) return;

    // ── String ───────────────────────────────────────────────────────────────
    if (engine.ctx.isString(val)) {
        const z_str = try engine.ctx.toZString(val);
        defer engine.ctx.freeZString(z_str);
        if (tl_is_sse) {
            try res.chunk("data: ");
            try res.chunk(z_str);
            try res.chunk("\n\n");
        } else {
            res.header("Content-Type", "text/plain; charset=utf-8");
            try res.chunk(z_str);
        }
        return;
    }

    // ── Object / array → JSON ────────────────────────────────────────────────
    const json_val = engine.ctx.jsonStringifySimple(val) catch |err| {
        std.debug.print("❌ [serve] JSON stringify failed: {}\n", .{err});
        res.status = 500;
        res.body = "Internal Server Error: failed to serialize JS result";
        return;
    };
    defer engine.ctx.freeValue(json_val);
    const json_str = try engine.ctx.toZString(json_val);
    defer engine.ctx.freeZString(json_str);
    if (tl_is_sse) {
        try res.chunk("data: ");
        try res.chunk(json_str);
        try res.chunk("\n\n");
    } else {
        res.header("Content-Type", "application/json");
        try res.chunk(json_str);
    }
}

/// POST /stream?base=<url>
/// Body: raw HTML  →  Response: processed HTML (text/html)
///
/// Mirrors the CLI `zxp stream` verb: feeds the request body through
/// ScriptEngine.beginStream / processStreamChunk / endStream (lexbor CSS
/// module, external stylesheets, inline scripts), then returns the
/// serialized document.
///
/// Pass `Accept: text/event-stream` to receive zxp.write() output as SSE.
pub fn streamHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const html = req.body() orelse {
        res.status = 400;
        res.body = "missing body: expected HTML";
        return;
    };

    const alloc = app_ctx.allocator;

    // Optional ?base=URL query param — sets rc.base_dir for asset resolution.
    const qs = try req.query();
    const base_dir: []const u8 = qs.get("base") orelse ".";

    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    // Hook zxp.write() → SSE/chunked output (same as runHandler).
    var writer_ctx = WriterContext{ .res = res, .is_sse = tl_is_sse };
    z.js_console.setChunkWriter(chunkWriter, &writer_ctx);
    defer z.js_console.clearChunkWriter();

    const opts: z.LoadPageOptions = .{
        .base_dir = base_dir,
        .load_stylesheets = true,
        .execute_scripts = true,
    };

    try engine.beginStream(opts);
    try engine.processStreamChunk(html);
    try engine.endStream(opts);

    // Serialize the processed document and return it.
    // Use res.chunk() so this works whether or not inline scripts already sent chunks
    // (mixing res.body with prior res.chunk() calls silently discards the body in httpz).
    const out = try engine.evalAsyncAs(alloc, []const u8, "document.documentElement.outerHTML", "<stream>");
    defer alloc.free(out);

    res.header("Content-Type", "text/html; charset=utf-8");
    try res.chunk(out);
}

/// POST /render?url=<url>[&width=800][&format=webp]
///
/// Fetches the target URL via curl streaming (curl write callback →
/// processStreamChunk → lexbor), applies CSS + scripts, paints the DOM,
/// and returns the encoded image as a binary response.
///
/// Query params:
///   url    — required, the page to fetch and render
///   width  — optional pixel width (default 800)
///   format — optional: png | jpg | webp | pdf (default png, detected from Accept)
///
/// Example:
///   curl "http://localhost:9984/render?url=https://example.com&format=webp" -o page.webp
pub fn renderProxyHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();

    const url = qs.get("url") orelse {
        res.status = 400;
        res.body = "missing ?url= query parameter";
        return;
    };

    const width: u32 = if (qs.get("width")) |w| std.fmt.parseInt(u32, w, 10) catch 800 else 800;
    const format: []const u8 = qs.get("format") orelse "png";

    const alloc = app_ctx.allocator;
    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    // Fetch the URL and stream it into the engine's lexbor document.
    try js_streamfrom.streamFromUrl(engine, url);

    // Paint and encode the fully-processed DOM.
    const js = try std.fmt.allocPrint(alloc, "zxp.encode(zxp.paintDOM(document.body, {d}), \"{s}\")", .{ width, format });
    defer alloc.free(js);

    const val = try engine.evalAsync(js, "<render>");
    defer engine.ctx.freeValue(val);

    if (!engine.ctx.isArrayBuffer(val)) {
        res.status = 500;
        res.body = "render failed: paintDOM did not return an ArrayBuffer";
        return;
    }

    const bytes = try engine.ctx.getArrayBuffer(val);
    res.header("Content-Type", sniffMime(bytes));
    res.body = try res.arena.dupe(u8, bytes);
}

/// POST /render_llm
///
/// Body: JSON { prompt, model?, system?, base_url?, width?, format? }
/// Response: JSON { "data": "<base64>", "mime": "<content-type>" }
///
/// Designed for interactive use — a form submits a POST and the JS client
/// sets img.src = `data:${mime};base64,${data}` to display the result.
pub fn renderLlmPostHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "Missing request body";
        return;
    };

    const PostBody = struct {
        prompt: []const u8 = "A simple table",
        model: []const u8 = "qwen2.5-coder:7b",
        system: []const u8 = js_llm.default_system,
        base_url: []const u8 = "http://localhost:11434",
        width: u32 = 800,
        format: []const u8 = "png",
    };

    const parsed = std.json.parseFromSlice(PostBody, res.arena, body, .{ .ignore_unknown_fields = true }) catch {
        res.status = 400;
        res.body = "Invalid JSON body";
        return;
    };
    const pb = parsed.value;

    const alloc = app_ctx.allocator;
    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    const html_post = try js_llm.streamFromOllama(alloc, pb.base_url, pb.model, pb.system, pb.prompt);
    defer alloc.free(html_post);
    try engine.loadHTML(html_post);

    const js = try std.fmt.allocPrint(alloc, "zxp.encode(zxp.paintDOM(document.body, {d}), \"{s}\")", .{ pb.width, pb.format });
    defer alloc.free(js);

    const val = try engine.evalAsync(js, "<render_llm_post>");
    defer engine.ctx.freeValue(val);

    if (!engine.ctx.isArrayBuffer(val)) {
        res.status = 500;
        res.body = "render_llm POST failed: paintDOM did not return an ArrayBuffer";
        return;
    }

    const img_bytes = try engine.ctx.getArrayBuffer(val);
    const mime = sniffMime(img_bytes);

    const encoder = std.base64.standard.Encoder;
    const b64_buf = try res.arena.alloc(u8, encoder.calcSize(img_bytes.len));
    _ = encoder.encode(b64_buf, img_bytes);

    const json = try std.fmt.allocPrint(res.arena, "{{\"data\":\"{s}\",\"mime\":\"{s}\"}}", .{ b64_buf, mime });
    res.header("Content-Type", "application/json");
    res.body = json;
}
/// GET /render_llm?prompt=<text>[&model=llama3.2][&system=<text>][&width=800][&format=png][&base_url=http://localhost:11434]
///
/// Streams an LLM prompt directly into the headless DOM via Ollama, paints
/// the result, and returns the encoded image.  Designed to be used as an
/// <img> src so the browser can embed generative UI without a JS pipeline:
///
///   <img src="http://localhost:9984/render_llm?prompt=3+metric+cards&format=webp">
pub fn renderLlmHandler(app_ctx: *AppContext, req: *httpz.Request, res: *httpz.Response) !void {
    const qs = try req.query();

    const prompt = qs.get("prompt") orelse "A simple table";
    const model = qs.get("model") orelse "qwen2.5-coder:7b";
    const system = qs.get("system") orelse js_llm.default_system;
    const base_url = qs.get("base_url") orelse "http://localhost:11434";
    const width: u32 = if (qs.get("width")) |w| std.fmt.parseInt(u32, w, 10) catch 800 else 800;
    const format: []const u8 = qs.get("format") orelse "png";

    const alloc = app_ctx.allocator;
    const zxp_rt = try zxp_runtime.getOrCreate(alloc, app_ctx.sandbox_root);
    var engine = try z.ScriptEngine.init(alloc, zxp_rt);
    defer engine.deinit();

    // Accumulate LLM output then parse at once — more reliable than streaming
    // for image generation (client waits for the full image regardless).
    const html = try js_llm.streamFromOllama(alloc, base_url, model, system, prompt);
    defer alloc.free(html);
    try engine.loadHTML(html);

    // Paint and encode the fully-processed DOM.
    const js = try std.fmt.allocPrint(alloc, "zxp.encode(zxp.paintDOM(document.body, {d}), \"{s}\")", .{ width, format });
    defer alloc.free(js);

    const val = try engine.evalAsync(js, "<render_llm>");
    defer engine.ctx.freeValue(val);

    if (!engine.ctx.isArrayBuffer(val)) {
        res.status = 500;
        res.body = "render_llm failed: paintDOM did not return an ArrayBuffer";
        return;
    }

    const bytes = try engine.ctx.getArrayBuffer(val);
    res.header("Content-Type", sniffMime(bytes));
    res.body = try res.arena.dupe(u8, bytes);
}
