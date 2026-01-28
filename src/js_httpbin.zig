// In js_native_bridge.zig (or a new file)
const std = @import("std");
const z = @import("root.zig");
const w = @import("wrapper.zig");
const qjs = z.qjs;
const js_marshal = @import("js_marshall.zig");
const js_native = @import("js_native_bridge.zig");
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

/// add an arena allocator from 'main' to be able to cleanup easily all the data allocated in the payload
pub const CaptureContext = struct {
    allocator: std.mem.Allocator,
    response: *HttpBinResponse,
};

pub const HttpBinResponse = struct {
    url: []const u8,
    origin: []const u8,
    // headers is an object in JS, so we map it to a specific struct
    // or we could implement HashMap support in jsToZig.
    // For now, let's grab specific headers.
    headers: HeadersInfo,

    // Optional fields
    json: ?[]const u8 = null,
};

pub const HeadersInfo = struct {
    Host: []const u8,
    @"User-Agent": []const u8, // @"" allows special chars in field names
    @"Content-Type": ?[]const u8 = null,
};

// JS: Native.receiveHttpBin(data_object)
pub fn js_receiveHttpBin(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    if (argc < 1) return ctx.throwTypeError("Expected 1 argument");

    const rc = RuntimeContext.get(ctx);

    // convert JS Object -> Zig Struct

    if (rc.payload) |payload_ptr| {
        const capture_ctx: *CaptureContext = @ptrCast(@alignCast(payload_ptr));

        // !!! Use the CAPTURE'S allocator (The Arena), not the Engine's allocator
        // This ensures the strings are allocated in the Arena we control in main.
        const persistent_data = js_marshal.jsToZig(
            capture_ctx.allocator,
            ctx,
            argv[0],
            HttpBinResponse,
        ) catch |err| {
            std.debug.print("Conversion Failed: {}\n", .{err});
            return ctx.throwTypeError("Data validation failed");
        };

        // write the data back to the response pointer
        capture_ctx.response.* = persistent_data;
    }

    return w.UNDEFINED;
}
