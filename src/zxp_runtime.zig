// --- zxp_runtime.zig ---
// Thread-local JSRuntime + Sandbox owner.
// One ZxpRuntime lives per OS thread for the duration of the thread.
//
// ScriptEngine (per-request) borrows a *ZxpRuntime and creates a fresh
// JSContext on top of the shared runtime.  This avoids the ~2.5 MB
// JS_NewRuntime2 allocation, GC setup, atom-table init, and Sandbox scan
// on every HTTP request.
//
// Interrupt handler design
// ────────────────────────
// The old handler stored a *ScriptEngine as the opaque pointer.
// Because ScriptEngine is per-request (not per-thread), the pointer was
// dangled between requests.  The fix: use a threadlocal i64 written by
// ScriptEngine and read by the handler — no pointer needed.

const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const js_security = z.js_security;

// ---------------------------------------------------------------------------
// Interrupt deadline — written by ScriptEngine, read by js_interrupt_handler.
// ---------------------------------------------------------------------------

/// ScriptEngine writes this before calling eval/run; clears it in deinit.
pub threadlocal var tl_deadline: i64 = 0;

export fn js_interrupt_handler(_: ?*qjs.JSRuntime, _: ?*anyopaque) callconv(.c) c_int {
    if (tl_deadline > 0 and std.time.milliTimestamp() > tl_deadline) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// ZxpRuntime
// ---------------------------------------------------------------------------

const import_map_json = @embedFile("examples/cdn_import_map.json");

pub const ZxpRuntime = struct {
    allocator: std.mem.Allocator,
    rt: *zqjs.Runtime,
    sandbox: js_security.Sandbox,
    /// Owned copy — passed to RuntimeContext.create every new ScriptEngine init.
    sandbox_root: []const u8,

    pub fn init(allocator: std.mem.Allocator, sandbox_root: []const u8) !*ZxpRuntime {
        const self = try allocator.create(ZxpRuntime);
        errdefer allocator.destroy(self);

        self.allocator = allocator;

        self.sandbox_root = try allocator.dupe(u8, sandbox_root);
        errdefer allocator.free(self.sandbox_root);

        self.sandbox = try js_security.Sandbox.initWithImportMap(
            allocator,
            sandbox_root,
            import_map_json,
        );
        errdefer self.sandbox.deinit();

        self.rt = try zqjs.Runtime.init(allocator);
        errdefer self.rt.deinit();

        self.rt.setMemoryLimit(256 * 1024 * 1024); // 256 MB
        self.rt.setGCThreshold(32 * 1024 * 1024); // 32 MB before GC
        self.rt.setMaxStackSize(16 * 1024 * 1024); // 16 MB stack
        self.rt.setInterruptHandler(js_interrupt_handler, null); // reads tl_deadline
        self.rt.setCanBlock(false);
        self.rt.setModuleLoader(
            js_security.js_secure_module_normalize,
            js_security.js_secure_module_loader,
            &self.sandbox,
        );

        return self;
    }

    pub fn deinit(self: *ZxpRuntime) void {
        self.rt.runGC();
        self.rt.deinit();
        self.sandbox.deinit();
        self.allocator.free(self.sandbox_root);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Thread-local server accessor + global registry for clean shutdown
// ---------------------------------------------------------------------------

threadlocal var tl_instance: ?*ZxpRuntime = null;

/// All ZxpRuntimes created by getOrCreate(), protected by a mutex.
/// Populated by worker threads; consumed once by destroyAll() on shutdown.
var g_mutex: std.Thread.Mutex = .{};
var g_all: std.ArrayListUnmanaged(*ZxpRuntime) = .{};

/// Server mode: lazily create (or return existing) thread-local ZxpRuntime.
/// The returned pointer is valid until the thread exits.
pub fn getOrCreate(allocator: std.mem.Allocator, sandbox_root: []const u8) !*ZxpRuntime {
    if (tl_instance) |rt| return rt;
    const rt = try ZxpRuntime.init(allocator, sandbox_root);
    tl_instance = rt;
    // Register in the global list so destroyAll() can reach it.
    g_mutex.lock();
    defer g_mutex.unlock();
    g_all.append(allocator, rt) catch {}; // best-effort; OOM here is not fatal
    return rt;
}

/// Free all thread-local ZxpRuntimes.  Call this AFTER the HTTP server's
/// thread pool has been joined (server.deinit()) so no worker threads are
/// still using the runtimes, and BEFORE debug_gpa.deinit().
pub fn destroyAll(allocator: std.mem.Allocator) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    for (g_all.items) |rt| rt.deinit();
    g_all.deinit(allocator);
    g_all = .{};
}
