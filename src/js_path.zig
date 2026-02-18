//! js_path.zig
const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

fn js_path_join(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const allocator = ctx.getAllocator(); // Use scratch allocator or heap

    // 1. Collect all arguments into a slice of paths
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (!ctx.isString(argv[@intCast(i)])) continue;
        const s = ctx.toCString(argv[@intCast(i)]) catch continue;
        // We defer freeing these C strings? No, std.fs.path.join copies them.
        // We must free them after join.
        paths.append(std.mem.span(s)) catch return ctx.throwOutOfMemory();
    }

    // 2. Perform Join
    const result = std.fs.path.join(allocator, paths.items) catch return ctx.throwOutOfMemory();
    defer allocator.free(result);

    // 3. Clean up C-Strings
    for (paths.items) |p| ctx.freeCString(p.ptr);

    return ctx.newString(result);
}

fn js_path_basename(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("path required");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    const base = std.fs.path.basename(path);
    return ctx.newString(base);
}

fn js_path_dirname(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("path required");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    const dir = std.fs.path.dirname(path) orelse ".";
    return ctx.newString(dir);
}

fn js_path_extname(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("path required");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    const ext = std.fs.path.extension(path);
    return ctx.newString(ext);
}

fn js_path_resolve(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const allocator = ctx.getAllocator();

    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const s = ctx.toCString(argv[@intCast(i)]) catch continue;
        paths.append(std.mem.span(s)) catch return ctx.throwOutOfMemory();
    }

    const result = std.fs.path.resolve(allocator, paths.items) catch return ctx.throwOutOfMemory();
    defer allocator.free(result);

    for (paths.items) |p| ctx.freeCString(p.ptr);

    return ctx.newString(result);
}

pub const PathBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        const path_obj = ctx.newObject();
        try ctx.setPropertyStr(path_obj, "join", ctx.newCFunction(js_path_join, "join", 1));
        try ctx.setPropertyStr(path_obj, "basename", ctx.newCFunction(js_path_basename, "basename", 1));
        try ctx.setPropertyStr(path_obj, "dirname", ctx.newCFunction(js_path_dirname, "dirname", 1));
        try ctx.setPropertyStr(path_obj, "extname", ctx.newCFunction(js_path_extname, "extname", 1));
        try ctx.setPropertyStr(path_obj, "resolve", ctx.newCFunction(js_path_resolve, "resolve", 1));

        // Separator (OS dependent)
        try ctx.setPropertyStr(path_obj, "sep", ctx.newString(&[_]u8{std.fs.path.sep}));

        try ctx.setPropertyStr(global, "path", path_obj);
    }
};
