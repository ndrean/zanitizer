const std = @import("std");
const z = @import("root.zig");
const httpz = @import("httpz");

const WriterContext = struct {
    res: *httpz.Response,
    is_sse: bool,
};

pub const Handler = struct {
    app_ctx: *AppContext,
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

pub fn healthHandler(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
}

// Bridges zxp.write(str) → res.chunk(str) for streaming output.
// Called from the thread-local set in runHandler.
fn chunkWriter(ctx: *anyopaque, data: []const u8) void {
    const res: *httpz.Response = @ptrCast(@alignCast(ctx));
    res.chunk(data) catch {};
}

pub fn runHandler(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing body: expected a JS script";
        return;
    };

    const alloc = handler.app_ctx.allocator;

    var engine = try z.ScriptEngine.init(alloc, handler.app_ctx.sandbox_root);
    defer engine.deinit();

    // Route zxp.write() calls → res.chunk() for this request's thread.
    z.js_console.setChunkWriter(chunkWriter, res);
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

    // Run the script. zxp.write() calls stream chunks back immediately via res.chunk().
    // Any return value is sent as a final chunk.
    const result = try engine.evalAsyncAndStringify(alloc, body, "<serve>");
    defer alloc.free(result);

    if (result.len > 0) {
        try res.chunk(result);
    }
}
