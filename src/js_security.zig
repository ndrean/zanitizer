const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

/// Security check: Ensures a resolved path does not escape the Current Working Directory.
///
/// Supports both Absolute paths (must start with CWD) and Relative paths (must not start with '..').
pub fn isSafePath(allocator: std.mem.Allocator, resolved_path: []const u8) bool {
    // 1. Absolute Path Check (Standard LFI protection)
    if (std.fs.path.isAbsolute(resolved_path)) {
        const cwd = std.process.getCwdAlloc(allocator) catch return false;
        defer allocator.free(cwd);
        // Must live inside CWD
        return std.mem.startsWith(u8, resolved_path, cwd);
    }

    // 2. Relative Path Check (For systems returning relative paths from resolve)
    // We only block if it explicitly tries to traverse UP ("..")
    // "js/app.js" -> Safe.   "../etc/passwd" -> Unsafe.
    return !std.mem.startsWith(u8, resolved_path, "..");
}

/// [security] Custom Module Firewall
///
/// Reactive Security reader callback triggered by QuickJS for `import Module` and runs BEFORE the file to import is loaded.
pub fn js_secure_module_normalize(
    ctx: ?*qjs.JSContext,
    module_base_name: [*c]const u8,
    module_name: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(opaque_ptr));
    const allocator = allocator_ptr.*;

    if (module_name == null) return null;
    const name_slice = std.mem.span(module_name);

    //  SSRF Prevention: block remote
    if (std.mem.startsWith(u8, name_slice, "http:") or
        std.mem.startsWith(u8, name_slice, "https:") or
        std.mem.startsWith(u8, name_slice, "//"))
    {
        _ = qjs.JS_ThrowReferenceError(ctx, "Security: Remote imports blocked '%s'", module_name);
        return null;
    }

    // resolves nested imports
    var resolved_path: []u8 = undefined;

    // Logic: resolve(base_dir, requested_name)
    // !! std.fs.path.resolve returns an ABSOLUTE LOGICAL path
    if (module_base_name) |base| {
        const base_slice = std.mem.span(base);
        // Ensure we have a valid directory from the base
        const base_dir = if (base_slice.len > 0) std.fs.path.dirname(base_slice) orelse "." else ".";
        resolved_path = std.fs.path.resolve(allocator, &.{ base_dir, name_slice }) catch return null;
    } else {
        resolved_path = std.fs.path.resolve(allocator, &.{name_slice}) catch return null;
    }
    defer allocator.free(resolved_path);

    // LFI Prevention: sandbox check
    if (!isSafePath(allocator, resolved_path)) {
        _ = qjs.JS_ThrowReferenceError(ctx, "Security: Path traversal detected '%s'", resolved_path.ptr);
        allocator.free(resolved_path); // Don't forget to free if we fail!
        return null;
    }

    // potential extension helper
    var final_path = resolved_path;
    var final_path_owned: ?[]u8 = null;

    const exact_exists = if (std.fs.cwd().access(final_path, .{})) |_| true else |_| false;

    if (!exact_exists) { // Try appending .js
        const with_ext = std.fmt.allocPrint(allocator, "{s}.js", .{final_path}) catch return null;
        if (std.fs.cwd().access(with_ext, .{}) == error.FileNotFound) {
            allocator.free(with_ext);
            // Both failed
            _ = qjs.JS_ThrowReferenceError(ctx, "Module not found: '%s' (looked in %s)", module_name, final_path.ptr);
            return null;
        }
        final_path = with_ext;
        final_path_owned = with_ext;
    }
    defer if (final_path_owned) |p| allocator.free(p);

    // to QuickJS
    return qjs.js_strndup(ctx, final_path.ptr, final_path.len);
}
