const std = @import("std");
const z = @import("zexplorer");
const qjs = z.qjs;
const zqjs = z.wrapper;

pub fn js_writeFileSync(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };

    if (argc < 2) return ctx.throwTypeError("writeFile requires path and ArrayBuffer");

    // 1. Get the file path
    const path = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(path);

    // 2. Extract the raw bytes from the ArrayBuffer
    var size: usize = 0;
    const buf_ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &size, argv[1]);
    if (buf_ptr == null) {
        return ctx.throwTypeError("Second argument must be an ArrayBuffer");
    }

    const data = buf_ptr[0..size];

    // 3. Write securely to the current directory (or your sandbox!)
    // Note: You should ideally route this through your js_security.Sandbox!
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |err| {
        std.debug.print("Write error: {any}\n", .{err});
        return ctx.throwInternalError("Failed to write file");
    };

    return zqjs.UNDEFINED;
}

pub fn install(ctx: zqjs.Context) !void {
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    // Create the zexplorer.fs namespace
    const zexplorer_obj = ctx.getPropertyStr(global, "zexplorer");
    defer ctx.freeValue(zexplorer_obj);

    const fs_obj = ctx.newObject();
    defer ctx.freeValue(fs_obj);

    const write_fn = ctx.newCFunction(js_writeFileSync, "writeFileSync", 2);
    try ctx.setPropertyStr(fs_obj, "writeFileSync", write_fn);

    try ctx.setPropertyStr(zexplorer_obj, "fs", fs_obj);
}
