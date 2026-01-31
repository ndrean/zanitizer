const std = @import("std");
const builtin = @import("builtin");
const z = @import("zexplorer");
const ScriptEngine = z.ScriptEngine;
const NativeBridge = z.native_bridge;
const js_httpbin = z.js_httpbin;
const HttpBinResponse = js_httpbin.HttpBinResponse;

pub var app_should_quit = std.atomic.Value(bool).init(false);
fn handleSigInt(_: c_int) callconv(.c) void {
    app_should_quit.store(true, .seq_cst);
}
// Setup function to call at start of main()
pub fn setupSignalHandler() void {
    if (builtin.os.tag == .windows) {
        // !! Windows needs a different approach (SetConsoleCtrlHandler),
        // but we focus on POSIX (Linux/macOS)
        return;
    }

    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    // Catch Ctrl+C (SIGINT)
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    // Optional: Catch Termination request (SIGTERM)
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn returnNativeBridge(gpa: std.mem.Allocator, sbx: []const u8) !void {
    z.print("\n=== Native Bridge Demo: JS ↔ Zig Data Transfer ------\n\n", .{});

    var engine = try ScriptEngine.init(gpa, sbx);
    defer engine.deinit();

    const CaptureContext = js_httpbin.CaptureContext;
    var captured_response: HttpBinResponse = undefined;

    var response_arena = std.heap.ArenaAllocator.init(gpa);
    defer response_arena.deinit();

    var capture_ctx = CaptureContext{
        .allocator = response_arena.allocator(),
        .response = &captured_response,
    };

    engine.rc.payload = &capture_ctx;

    const ctx = engine.ctx;
    NativeBridge.installNativeBridge(ctx);

    z.print("\n--- Test 11: Capture Http Request return ---\n\n", .{});
    const js =
        \\fetch('https://httpbin.org/get', {
        \\    headers: { "Content-Type": "application/json" }
        \\})
        \\.then(res => res.json())
        \\.then(data => {
        \\    console.log("[JS] Executing a native Zig function...");
        \\    // Native is the global object created by js_native_bridge
        \\    Native.receiveHttpBin(data); 
        \\    console.log("[JS] ", data.origin);
        \\})
        \\.catch(err => console.log("Error:", err));
    ;

    const result = try engine.eval(js, "test", .module);
    defer ctx.freeValue(result);
    try engine.run();

    z.print("[Zig] captured data: {s}, {s}\n", .{ captured_response.url, captured_response.origin });

    z.print("\n✅ JavaScript can call Zig functions\n", .{});
    z.print("Data flows: JS → Zig → JS\n\n", .{});
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.c_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const sandbox_root = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(sandbox_root);
    setupSignalHandler();

    try returnNativeBridge(gpa, sandbox_root);
}
