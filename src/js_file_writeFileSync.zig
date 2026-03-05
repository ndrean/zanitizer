const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// __native_readFileSync(path: string) → ArrayBuffer
/// Reads a file synchronously and returns its bytes as an ArrayBuffer.
pub fn js_readFileSync(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("readFileSync requires a path");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    const rc = RuntimeContext.get(ctx);
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return ctx.throwInternalError(@errorName(err));
    };
    defer file.close();

    const content = file.readToEndAlloc(rc.allocator, 500 * 1024 * 1024) catch |err| {
        return ctx.throwInternalError(@errorName(err));
    };
    defer rc.allocator.free(content);

    return ctx.newArrayBufferCopy(content);
}

/// __native_writeFileSync(path: string, data: string | ArrayBuffer | TypedArray) → undefined
/// Writes data to a file synchronously, overwriting any existing content.
pub fn js_writeFileSync(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("writeFileSync requires path and data");

    const path_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(path_c);
    const path = std.mem.span(path_c);

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return ctx.throwInternalError(@errorName(err));
    };
    defer file.close();

    if (ctx.isString(argv[1])) {
        const data_c = ctx.toCString(argv[1]) catch return zqjs.EXCEPTION;
        defer ctx.freeCString(data_c);
        file.writeAll(std.mem.span(data_c)) catch |err| {
            return ctx.throwInternalError(@errorName(err));
        };
    } else if (ctx.isArrayBuffer(argv[1])) {
        const data = ctx.getArrayBuffer(argv[1]) catch return ctx.throwTypeError("Invalid ArrayBuffer");
        file.writeAll(data) catch |err| {
            return ctx.throwInternalError(@errorName(err));
        };
    } else {
        // TypedArray (Uint8Array, etc.) — get its backing ArrayBuffer
        const ab = ctx.getTypedArrayBuffer(argv[1]) catch return ctx.throwTypeError("writeFileSync: data must be string, ArrayBuffer, or TypedArray");
        defer ctx.freeValue(ab.buffer);
        const data = ctx.getArrayBuffer(ab.buffer) catch return ctx.throwTypeError("Invalid TypedArray buffer");
        file.writeAll(data[ab.byte_offset .. ab.byte_offset + ab.byte_length]) catch |err| {
            return ctx.throwInternalError(@errorName(err));
        };
    }

    return zqjs.UNDEFINED;
}

/// __native_getCwd() → string
/// Returns the server's current working directory as a string.
pub fn js_getCwd(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);
    const cwd = std.process.getCwdAlloc(rc.allocator) catch |err| {
        return ctx.throwInternalError(@errorName(err));
    };
    defer rc.allocator.free(cwd);
    return ctx.newString(cwd);
}
