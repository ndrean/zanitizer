const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const posix = std.posix;

// pub fn openFileNoSymlinkEscape(sandbox: *Sandbox, rel_path: []const u8) !std.fs.File {
//     var it = std.mem.splitScalar(u8, rel_path, '/');

//     // Start at the sandbox root
//     var current_dir = sandbox.dir;

//     // Track directories we open so we can close them when we return
//     // We use ArrayListUnmanaged as requested
//     var opened_dirs: std.ArrayListUnmanaged(std.fs.Dir) = .empty;
//     defer {
//         for (opened_dirs.items) |*d| d.close();
//         opened_dirs.deinit(sandbox.allocator);
//     }

//     var pending_component: ?[]const u8 = null;

//     // 1. Walk the directories using standard openDir (which supports .no_follow)
//     while (it.next()) |component| {
//         if (component.len == 0) continue;

//         // If we have a pending component, it means we found a NEW component after it.
//         // Therefore, the PENDING component must be a directory. Open it.
//         if (pending_component) |dir_name| {
//             // openDir supports .no_follow in OpenDirOptions
//             const next_dir = current_dir.openDir(dir_name, .{
//                 .iterate = false,
//                 .no_follow = true, // 🔐 BLOCK SYMLINKS
//             }) catch |err| {
//                 if (err == error.NotDir) return error.AccessDenied;
//                 return err;
//             };

//             try opened_dirs.append(sandbox.allocator, next_dir);
//             current_dir = next_dir;
//         }

//         pending_component = component;
//     }

//     // 2. Open the Final File using POSIX openat
//     // We CANNOT use current_dir.openFile() because OpenFlags lacks .no_follow
//     const filename = pending_component orelse return error.InvalidPath;

//     // openat requires a null-terminated path
//     const filename_z = try sandbox.allocator.dupeZ(u8, filename);
//     defer sandbox.allocator.free(filename_z);

//     // Construct flags using Zig 0.15.2 packed struct syntax
//     // We assume std.posix.O maps to the struct definition you provided
//     const flags = posix.O{
//         .ACCMODE = .RDONLY,
//         .NOFOLLOW = true, // 🔐 BLOCK SYMLINKS
//         .CLOEXEC = true,
//     };

//     // Use the raw File Descriptor from the loop's current_dir
//     const fd = try posix.openat(current_dir.fd, filename_z, flags, 0);

//     return std.fs.File{ .handle = fd };
// }

pub fn openFileNoSymlinkEscape(sandbox: *Sandbox, rel_path: []const u8) !std.fs.File {
    var it = std.mem.splitScalar(u8, rel_path, '/');

    var current_dir = sandbox.dir;
    var dir_stack: [16]std.fs.Dir = undefined;
    var dir_count: usize = 0;

    // Cleanup: Close all opened intermediate directories
    defer {
        var i: usize = 0;
        while (i < dir_count) : (i += 1) {
            dir_stack[i].close();
        }
    }

    var pending_component: ?[]const u8 = null;

    // 1. Walk directories
    while (it.next()) |component| {
        if (component.len == 0) continue;

        if (std.mem.eql(u8, component, "..")) return error.AccessDenied;
        if (std.mem.eql(u8, component, ".")) continue;

        if (pending_component) |dir_name| {
            // Check depth limit
            if (dir_count >= dir_stack.len) return error.NameTooLong; // or AccessDenied

            // Open next directory safely
            const next_dir = current_dir.openDir(dir_name, .{
                .iterate = false,
                .no_follow = true,
            }) catch |err| {
                if (err == error.NotDir) return error.AccessDenied;
                return err;
            };

            // Push to stack
            dir_stack[dir_count] = next_dir;
            dir_count += 1;
            current_dir = next_dir;
        }

        pending_component = component;
    }

    // Open Final File (Low-Level POSIX)
    const filename = pending_component orelse return error.InvalidPath;

    // Stack-allocated filename buffer
    if (filename.len > posix.NAME_MAX) return error.NameTooLong;

    var name_buf: [posix.NAME_MAX + 1]u8 = undefined;
    @memcpy(name_buf[0..filename.len], filename);
    name_buf[filename.len] = 0; // Null terminate manually

    const flags_struct = posix.O{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };

    // Open using the raw FD from current_dir
    // We slice the buffer with :0 to create a null-terminated sentinel slice
    const fd = try posix.openat(current_dir.fd, name_buf[0..filename.len :0], flags_struct, 0);

    return std.fs.File{ .handle = fd };
}

pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Sandbox {
        // Open the directory ONCE.
        // .iterate=false is safer if you don't need directory listings.
        const dir = try std.fs.openDirAbsolute(root_path, .{ .iterate = false });
        return Sandbox{
            .allocator = allocator,
            .dir = dir,
        };
    }

    pub fn deinit(self: *Sandbox) void {
        self.dir.close();
    }
};

// Helper to detect URLs
fn isRemote(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "http:") or std.mem.startsWith(u8, path, "https:");
}

/// [Normalizer] Resolves import paths logically WITHOUT touching the filesystem.
/// Prevents '..' from escaping the sandbox root.
pub fn js_secure_module_normalize(
    ctx: ?*qjs.JSContext,
    module_base_name: [*c]const u8,
    module_name: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) [*c]u8 {
    z.print("[Zig] SECURE RESOLVER\n", .{});
    const sandbox: *Sandbox = @ptrCast(@alignCast(opaque_ptr));
    const allocator = sandbox.allocator;

    if (module_name == null) return null;
    const name_slice = std.mem.span(module_name);

    if (isRemote(name_slice)) {
        return z.qjs.js_strdup(ctx, module_name);
    }

    // 1. Block basic nonsense
    if (std.mem.startsWith(u8, name_slice, "http") or std.mem.startsWith(u8, name_slice, "//")) {
        _ = qjs.JS_ThrowReferenceError(ctx, "Remote imports blocked");
        return null;
    }

    // 2. Determine Base (Relative to Sandbox)
    // If we are in "js/test/app.js", base is "js/test"
    var base_dir: []const u8 = ".";
    if (module_base_name) |base| {
        const base_span = std.mem.span(base);
        if (base_span.len > 0) {
            base_dir = std.fs.path.dirname(base_span) orelse ".";
        }
    }

    // 3. THE FIX: Virtual Resolution
    // We start with "/" to force Zig to do pure math, ignoring CWD.
    // "js/test" + "../vendor/lib.js" becomes "/js/vendor/lib.js"
    const resolved_absolute = std.fs.path.resolve(allocator, &.{ "/", base_dir, name_slice }) catch return null;
    defer allocator.free(resolved_absolute);

    // 4. Strip the fake "/" to get the clean Sandbox Path
    // "/js/vendor/lib.js" -> "js/vendor/lib.js"
    const relative_path = if (std.mem.startsWith(u8, resolved_absolute, "/"))
        resolved_absolute[1..]
    else
        resolved_absolute;

    // 5. Extension Check (Quick & Dirty)
    // We check existence relative to the Sandbox Root (using our stack walker would be too heavy here,
    // so we trust the OS cache for this simple check, but the LOADER enforces security).
    // Note: To be 100% strict, we should use the walker here too, but checking exact path or + .js is usually enough.

    // Default to strict exact path
    var final_path = relative_path;
    var final_path_owned: ?[]u8 = null;

    // Only try appending .js if the file doesn't seem to exist
    // We use the sandbox dir FD to check existence (cheap)
    if (sandbox.dir.access(final_path, .{}) == error.FileNotFound) {
        const with_ext = std.fmt.allocPrint(allocator, "{s}.js", .{final_path}) catch return null;
        // If that exists, use it
        if (sandbox.dir.access(with_ext, .{}) != error.FileNotFound) {
            final_path = with_ext;
            final_path_owned = with_ext;
        } else {
            // Clean up if neither worked
            allocator.free(with_ext);
        }
    }

    // Return safely
    defer if (final_path_owned) |p| allocator.free(p);
    return qjs.js_strndup(ctx, final_path.ptr, final_path.len);
}

/// [Loader] Opens file using Directory File Descriptor (Kernel Enforcement)
pub fn js_secure_module_loader(
    ctx: ?*qjs.JSContext,
    module_name: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) ?*qjs.JSModuleDef {
    z.print("[Zig] SECURE  LOADER \n", .{});
    const sandbox: *Sandbox = @ptrCast(@alignCast(opaque_ptr));
    const allocator = sandbox.allocator;
    const name = std.mem.span(module_name);

    if (isRemote(name)) {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        defer allocating.deinit();

        var client: std.http.Client = .{
            .allocator = allocator,
        };
        defer client.deinit();

        const response = client.fetch(.{
            .method = .GET,
            .location = .{ .url = name },
            .response_writer = &allocating.writer,
        }) catch return null;

        std.debug.assert(response.status == .ok);
        const code = allocating.toOwnedSlice() catch return null;
        defer allocator.free(code);
        std.debug.assert(code.len > 0);
        const func_val = qjs.JS_Eval(
            ctx,
            code.ptr,
            code.len,
            module_name,
            qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY,
        );

        if (qjs.JS_IsException(func_val)) return null;
        return @ptrCast(qjs.JS_VALUE_GET_PTR(func_val));
    } else {

        // 1. Kernel-Level Security Check
        const file = openFileNoSymlinkEscape(sandbox, name) catch |err| {
            if (err == error.FileNotFound) {
                _ = qjs.JS_ThrowReferenceError(ctx, "Module not found: %s", module_name);
            } else if (err == error.AccessDenied or err == error.SymLinkLoop) {
                _ = qjs.JS_ThrowReferenceError(ctx, "Security: Access denied (Symlink or Permission)");
            } else {
                _ = qjs.JS_ThrowReferenceError(ctx, "Failed to load module");
            }
            return null;
        };
        defer file.close();

        // 2. Read Content (Standard)
        const MAX_SIZE = 5 * 1024 * 1024; // 5MB limit
        const source = file.readToEndAllocOptions(
            sandbox.allocator,
            MAX_SIZE,
            null,
            std.mem.Alignment.fromByteUnits(1),
            0,
        ) catch {
            _ = qjs.JS_ThrowInternalError(ctx, "Module too large or read failed");
            return null;
        };
        defer sandbox.allocator.free(source);

        // 3. Compile & Return (Standard)
        const func_val = qjs.JS_Eval(
            ctx,
            source.ptr,
            source.len,
            module_name,
            qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY,
        );

        if (qjs.JS_IsException(func_val)) return null;
        return @ptrCast(qjs.JS_VALUE_GET_PTR(func_val));
    }
}

/// [security] Hybrid Path Validator
/// Ensures a resolved path does not logically escape the CWD.
/// - Absolute paths must start with the CWD.
/// - Relative paths must not start with ".." (upward traversal).
pub fn isSafePath(allocator: std.mem.Allocator, resolved_path: []const u8) bool {
    // 1. Absolute Path Check (Standard LFI protection)
    if (std.fs.path.isAbsolute(resolved_path)) {
        // We get CWD every time to ensure we aren't using a stale cached path
        const cwd = std.process.getCwdAlloc(allocator) catch return false;
        defer allocator.free(cwd);
        // Must live inside CWD
        return std.mem.startsWith(u8, resolved_path, cwd);
    }

    // 2. Relative Path Check (For systems returning relative paths from resolve)
    // We only block if it explicitly tries to traverse UP ("..")
    // "js/app.js" -> Safe.   "../etc/passwd" -> Unsafe.
    // Note: 'resolve' usually collapses inner "..", so checking the prefix is sufficient.
    return !std.mem.startsWith(u8, resolved_path, "..");
}
