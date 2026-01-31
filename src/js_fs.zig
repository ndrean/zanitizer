const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const EventLoop = @import("event_loop.zig").EventLoop;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const AsyncBridge = @import("async_bridge.zig");
const js_readable_stream = @import("js_readable_stream.zig");
const js_writable_stream = @import("js_writable_stream.zig");
const js_file = @import("js_file.zig");

// ==================================================================
// PAYLOADS

const FileReadPayload = struct {
    path: []u8,
};

const FileWritePayload = struct {
    path: []u8,
    data: []u8,
};

const PathPayload = struct {
    path: []u8,

    /// Called by bindAsyncJson wrapper to cleanup payload with correct allocator
    pub fn deinit(self: PathPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

const CopyPayload = struct {
    src: []u8,
    dst: []u8,
    pub fn deinit(self: CopyPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.src);
        allocator.free(self.dst);
    }
};

const WritePayload = struct {
    path: []u8,
    data: []u8,
    pub fn deinit(self: WritePayload, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.data);
    }
};

// ===============================================================
// RESULT TYPES (for JSON serialization)

const StatResult = struct {
    size: i64, // Use i64 instead of u64 for JSON compatibility
    mtime: i64, // milliseconds since epoch
    isFile: bool,
    isDirectory: bool,
    isSymlink: bool,
};

const ExistsResult = struct {
    exists: bool,
};

const DirEntry = struct {
    name: []const u8,
    isFile: bool,
    isDirectory: bool,
    isSymlink: bool,
};

const ReadDirResult = struct {
    entries: []DirEntry,
};

// ===============================================================
// WORKER FUNCTIONS (Run on Background Thread)

fn js_createReadStream(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Path required");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    // Create the stream (opens file, reads are async via worker threads)
    const stream_val = js_readable_stream.createStreamFromFile(ctx, path) catch |err| {
        return ctx.throwInternalError(@errorName(err));
    };

    return stream_val;
}

fn js_createWriteStream(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Path required");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    // Create the stream (opens/creates file, writes are async via worker threads)
    const stream_val = js_writable_stream.createStreamToFile(ctx, path) catch |err| {
        return ctx.throwInternalError(@errorName(err));
    };

    return stream_val;
}

// Result is []u8 (Text or Binary)
fn workReadFile(allocator: std.mem.Allocator, payload: FileReadPayload) ![]u8 {
    const file = try std.fs.cwd().openFile(payload.path, .{});
    defer file.close();

    // 2. Read All (Limit to 500MB for safety)
    const content = try file.readToEndAlloc(allocator, 500 * 1024 * 1024);

    // 3. Free the path (input) since we are done with it
    allocator.free(payload.path);

    return content;
}

// Result is []u8 (Empty string on success, or error caught by bridge)
fn workWriteFile(allocator: std.mem.Allocator, payload: FileWritePayload) ![]u8 {
    // 1. Create/Overwrite File
    const file = try std.fs.cwd().createFile(payload.path, .{});
    defer file.close();

    // 2. Write Data
    try file.writeAll(payload.data);

    // 3. Cleanup inputs
    allocator.free(payload.path);
    allocator.free(payload.data);

    // Return empty string to signal success
    return try allocator.dupe(u8, "");
}

fn workStat(_: std.mem.Allocator, payload: PathPayload) !StatResult {
    // Note: payload cleanup handled by bindAsyncJson wrapper via deinit()
    const file = std.fs.cwd().openFile(payload.path, .{}) catch |err| {
        // Try as directory
        if (err == error.IsDir) {
            var dir = try std.fs.cwd().openDir(payload.path, .{});
            defer dir.close();
            const stat = try dir.stat();
            return StatResult{
                .size = 0,
                .mtime = @intCast(@divFloor(stat.mtime, std.time.ns_per_ms)),
                .isFile = false,
                .isDirectory = true,
                .isSymlink = stat.kind == .sym_link,
            };
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    return StatResult{
        .size = @intCast(stat.size),
        .mtime = @intCast(@divFloor(stat.mtime, std.time.ns_per_ms)),
        .isFile = stat.kind == .file,
        .isDirectory = stat.kind == .directory,
        .isSymlink = stat.kind == .sym_link,
    };
}

fn workExists(_: std.mem.Allocator, payload: PathPayload) !ExistsResult {
    // Note: payload cleanup handled by bindAsyncJson wrapper via deinit()
    std.fs.cwd().access(payload.path, .{}) catch {
        return ExistsResult{ .exists = false };
    };
    return ExistsResult{ .exists = true };
}

fn workReadDir(allocator: std.mem.Allocator, payload: PathPayload) !ReadDirResult {
    // Note: payload cleanup handled by bindAsyncJson wrapper via deinit()
    var dir = try std.fs.cwd().openDir(payload.path, .{ .iterate = true });
    defer dir.close();

    var entries: std.ArrayListUnmanaged(DirEntry) = .empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .isFile = entry.kind == .file,
            .isDirectory = entry.kind == .directory,
            .isSymlink = entry.kind == .sym_link,
        });
    }

    return ReadDirResult{
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn workMkDir(allocator: std.mem.Allocator, p: PathPayload) ![]u8 {
    try std.fs.cwd().makePath(p.path);
    p.deinit(allocator);
    return try allocator.dupe(u8, "true");
}

fn workRm(allocator: std.mem.Allocator, p: PathPayload) ![]u8 {
    try std.fs.cwd().deleteTree(p.path);
    p.deinit(allocator);
    return try allocator.dupe(u8, "true");
}

fn workCopy(allocator: std.mem.Allocator, p: CopyPayload) ![]u8 {
    try std.fs.cwd().copyFile(p.src, std.fs.cwd(), p.dst, .{});
    p.deinit(allocator);
    return try allocator.dupe(u8, "true");
}

fn workRename(allocator: std.mem.Allocator, p: CopyPayload) ![]u8 {
    try std.fs.cwd().rename(p.src, p.dst);
    p.deinit(allocator);
    return try allocator.dupe(u8, "true");
}

fn js_fileFromPath(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("Path required");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path_slice: []const u8 = std.mem.span(path_c);

    // (to get real size and mtime)
    const file = std.fs.cwd().openFile(path_slice, .{}) catch return ctx.throwInternalError("File not found");
    defer file.close();
    const stat = file.stat() catch return ctx.throwInternalError("Stat failed");

    // Create the Zig FileObject
    const file_obj = rc.allocator.create(js_file.FileObject) catch return ctx.throwOutOfMemory();

    var arena = std.heap.ArenaAllocator.init(rc.allocator);
    const arena_alloc = arena.allocator();

    // Duplicate path for the object
    const path_dupe = arena_alloc.dupe(u8, path_slice) catch return ctx.throwOutOfMemory();
    // Default name is the basename of the path
    const name_dupe = arena_alloc.dupe(u8, std.fs.path.basename(path_slice)) catch return ctx.throwOutOfMemory();
    const mime_dupe = arena_alloc.dupe(u8, "application/octet-stream") catch return ctx.throwOutOfMemory();

    const mtime_ms: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_ms));
    file_obj.* = .{
        .blob = .{
            .parent_allocator = rc.allocator,
            .data = &.{}, // Empty memory data
            .mime_type = mime_dupe,
            .arena = arena,
        },
        .name = name_dupe,
        .last_modified = mtime_ms,
        .disk_size = stat.size,
        .path = path_dupe, // <--- THE MAGIC FIELD for Zero-Copy
    };

    // Wrap in JS Object
    const js_obj = ctx.newObjectClass(rc.classes.file);
    ctx.setOpaque(js_obj, file_obj) catch return ctx.throwOutOfMemory();

    return js_obj;
}

// ==========================================================
// PARSERS (Run on Main Thread)

fn parseReadArgs(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !FileReadPayload {
    if (args.len < 1) return error.InvalidArgs;

    const path_c = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_c);

    // Copy path for the worker thread
    const path = try loop.allocator.dupe(u8, std.mem.span(path_c));
    return FileReadPayload{ .path = path };
}

fn parsePathArg(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !PathPayload {
    if (args.len < 1) return error.InvalidArgs;

    const path_c = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_c);

    return PathPayload{ .path = try loop.allocator.dupe(u8, std.mem.span(path_c)) };
}

fn parseWriteArgs(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !FileWritePayload {
    if (args.len < 2) return error.InvalidArgs;

    const path_c = try ctx.toCString(args[0]);
    defer ctx.freeCString(path_c);

    // Handle Data (String or Buffer)
    var data_slice: []const u8 = "";
    var free_cstr: ?[*:0]const u8 = null;

    if (ctx.isString(args[1])) {
        const c_str = try ctx.toCString(args[1]);
        data_slice = std.mem.span(c_str);
        free_cstr = c_str;
    } else {
        // Assume ArrayBuffer
        var len: usize = 0;
        const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &len, args[1]);
        if (ptr) |p| {
            data_slice = p[0..len];
        } else {
            return error.InvalidArgs;
        }
    }
    defer if (free_cstr) |ptr| ctx.freeCString(ptr);

    return FileWritePayload{
        .path = try loop.allocator.dupe(u8, std.mem.span(path_c)),
        .data = try loop.allocator.dupe(u8, data_slice),
    };
}

// fn parseOnePath(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !PathPayload {
//     if (args.len < 1) return error.InvalidArgs;
//     const p = try ctx.toCString(args[0]);
//     defer ctx.freeCString(p);

//     // Use the loop's allocator (Tracked!)
//     const path_dupe = try loop.allocator.dupe(u8, std.mem.span(p));
//     return PathPayload{ .path = path_dupe };
// }

fn parseTwoPaths(loop: *EventLoop, ctx: zqjs.Context, args: []const zqjs.Value) !CopyPayload {
    if (args.len < 2) return error.InvalidArgs;

    const src_c = try ctx.toCString(args[0]);
    defer ctx.freeCString(src_c);
    const dst_c = try ctx.toCString(args[1]);
    defer ctx.freeCString(dst_c);

    // Use the loop's allocator
    return CopyPayload{
        .src = try loop.allocator.dupe(u8, std.mem.span(src_c)),
        .dst = try loop.allocator.dupe(u8, std.mem.span(dst_c)),
    };
}

// ============================================================
// INSTALLER

pub const FSBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const fs = ctx.newObject();

        // 1. readFile (Text)
        const read_fn = ctx.newCFunction(AsyncBridge.bindAsync(FileReadPayload, parseReadArgs, workReadFile), "readFile", 1);
        try ctx.setPropertyStr(fs, "readFile", read_fn);

        // readFileBuffer (Binary - ArrayBuffer)
        // const read_bin_fn = ctx.newCFunction(AsyncBridge.bindAsyncBuffer(FileReadPayload, parseReadArgs, workReadFile), "readFileBuffer", 1);
        // try ctx.setPropertyStr(fs, "readFileBuffer", read_bin_fn);

        // writeFile
        const write_fn = ctx.newCFunction(AsyncBridge.bindAsync(FileWritePayload, parseWriteArgs, workWriteFile), "writeFile", 2);
        try ctx.setPropertyStr(fs, "writeFile", write_fn);

        // stat - returns {size, mtime, isFile, isDirectory, isSymlink}
        const stat_fn = ctx.newCFunction(AsyncBridge.bindAsyncJson(PathPayload, StatResult, parsePathArg, workStat), "stat", 1);
        try ctx.setPropertyStr(fs, "stat", stat_fn);

        // exists - returns {exists: boolean}
        const exists_fn = ctx.newCFunction(AsyncBridge.bindAsyncJson(PathPayload, ExistsResult, parsePathArg, workExists), "exists", 1);
        try ctx.setPropertyStr(fs, "exists", exists_fn);

        // readDir - returns {entries: [{name, isFile, isDirectory, isSymlink}]}
        const readdir_fn = ctx.newCFunction(AsyncBridge.bindAsyncJson(PathPayload, ReadDirResult, parsePathArg, workReadDir), "readDir", 1);
        try ctx.setPropertyStr(fs, "readDir", readdir_fn);

        // try ctx.setPropertyStr(fs, "mkdir", ctx.newCFunction(AsyncBridge.bindAsync(PathPayload, parseOnePath, workMkDir), "mkdir", 1));

        // path -> promise
        // try ctx.setPropertyStr(fs, "rm", ctx.newCFunction(AsyncBridge.bindAsync(PathPayload, parseOnePath, workRm), "rm", 1));

        // cp -> promise
        try ctx.setPropertyStr(fs, "copyFile", ctx.newCFunction(AsyncBridge.bindAsync(CopyPayload, parseTwoPaths, workCopy), "copyFile", 2));

        // rnm -> promise
        try ctx.setPropertyStr(fs, "rename", ctx.newCFunction(AsyncBridge.bindAsync(CopyPayload, parseTwoPaths, workRename), "rename", 2));

        const fileFromPath_fn = ctx.newCFunction(js_fileFromPath, "fileFromPath", 1);
        try ctx.setPropertyStr(fs, "fileFromPath", fileFromPath_fn);

        // createReadStream - returns a ReadableStream for async file reading
        const crs_fn = ctx.newCFunction(js_createReadStream, "createReadStream", 1);
        try ctx.setPropertyStr(fs, "createReadStream", crs_fn);

        // createWriteStream - returns a WritableStream for async file writing
        const cws_fn = ctx.newCFunction(js_createWriteStream, "createWriteStream", 1);
        try ctx.setPropertyStr(fs, "createWriteStream", cws_fn);

        try ctx.setPropertyStr(global, "fs", fs);
    }
};
