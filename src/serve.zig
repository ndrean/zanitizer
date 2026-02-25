const std = @import("std");
const z = @import("root.zig");
const httpz = @import("httpz");
const zxp_runtime = @import("zxp_runtime.zig");

const WriterContext = struct {
    res: *httpz.Response,
    is_sse: bool,
};

/// Set by dispatch() so runHandler() can format its final result correctly.
threadlocal var tl_is_sse: bool = false;

pub const Handler = struct {
    app_ctx: *AppContext,
    pub fn dispatch(self: *Handler, action: httpz.Action(*AppContext), req: *httpz.Request, res: *httpz.Response) !void {
        var is_sse = false;

        if (req.header("accept")) |accept| {
            if (std.mem.indexOf(u8, accept, "text/event-stream") != null) {
                is_sse = true;
                res.header("Content-Type", "text/event-stream");
                res.header("Cache-Control", "no-cache");
                res.header("Connection", "keep-alive");
            }
        }

        // Create the context on the stack (valid for the duration of this function/request)
        var writer_ctx = WriterContext{
            .res = res,
            .is_sse = is_sse,
        };

        // Hook the console.log / zxp.write output to this response
        z.js_console.setChunkWriter(chunkWriter, &writer_ctx);
        defer z.js_console.clearChunkWriter();

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

pub fn healthHandler(_: *AppContext, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
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
    // const res: *httpz.Response = @ptrCast(@alignCast(ptr));
    // res.chunk(data) catch {};
    const ctx: *WriterContext = @ptrCast(@alignCast(ptr));
    if (ctx.is_sse) {
        // Arena is freed by httpz at end of request — no need to free individually.
        const sse_data = std.fmt.allocPrint(ctx.res.arena, "data: {s}\n\n", .{data}) catch return;
        ctx.res.chunk(sse_data) catch {};
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
            try res.chunk(try std.fmt.allocPrint(res.arena, "data: {s}\n\n", .{z_str}));
        } else {
            res.header("Content-Type", "text/plain; charset=utf-8");
            res.body = try res.arena.dupe(u8, z_str);
        }
        return;
    }

    // ── Object / array → JSON ────────────────────────────────────────────────
    const json_val = engine.ctx.jsonStringifySimple(val) catch return;
    defer engine.ctx.freeValue(json_val);
    const json_str = try engine.ctx.toZString(json_val);
    defer engine.ctx.freeZString(json_str);
    if (tl_is_sse) {
        try res.chunk(try std.fmt.allocPrint(res.arena, "data: {s}\n\n", .{json_str}));
    } else {
        res.header("Content-Type", "application/json");
        res.body = try res.arena.dupe(u8, json_str);
    }
}
