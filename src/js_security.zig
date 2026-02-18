const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const posix = std.posix;
const curl = @import("curl");
const ImportMap = @import("js_import_map.zig").ImportMap;
const ScriptEngine = @import("script_engine.zig").ScriptEngine;

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

    // [SECURITY] Hardlink escape detection
    // A hardlink to a file outside the sandbox would have a different device ID
    const file_stat = try posix.fstat(fd);
    const sandbox_stat = try posix.fstat(sandbox.dir.fd);
    if (file_stat.dev != sandbox_stat.dev) {
        posix.close(fd);
        return error.AccessDenied; // Cross-device hardlink attempt
    }

    return std.fs.File{ .handle = fd };
}

pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    import_map: ImportMap,

    /// Initialize sandbox without import map (pass-through mode)
    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Sandbox {
        return initWithImportMap(allocator, root_path, null);
    }

    /// Initialize sandbox with optional import map JSON config
    /// Pass null or empty string for pass-through mode (no import map)
    pub fn initWithImportMap(allocator: std.mem.Allocator, root_path: []const u8, import_map_json: ?[]const u8) !Sandbox {
        // Open the directory ONCE.
        // .iterate=false is safer if you don't need directory listings.
        var dir = try std.fs.openDirAbsolute(root_path, .{ .iterate = false });
        errdefer dir.close();

        var import_map = try ImportMap.fromJson(allocator, import_map_json);
        errdefer import_map.deinit();

        return Sandbox{
            .allocator = allocator,
            .dir = dir,
            .import_map = import_map,
        };
    }

    pub fn deinit(self: *Sandbox) void {
        self.import_map.deinit();
        self.dir.close();
    }
};

// Helper to detect URLs
fn isRemote(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "http:") or std.mem.startsWith(u8, path, "https:");
}

/// Resolve a relative URL against a base URL
/// e.g., base="https://cdn.jsdelivr.net/npm/react-dom@18.2.0/+esm", rel="npm/react@18.2.0/+esm"
/// returns "https://cdn.jsdelivr.net/npm/react@18.2.0/+esm"
fn resolveRemoteUrl(allocator: std.mem.Allocator, base_url: []const u8, relative: []const u8) ![]u8 {
    // Find the scheme (https://)
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidUrl;
    const after_scheme = base_url[scheme_end + 3 ..];

    // Find the host end (first / after scheme)
    const host_end = std.mem.indexOf(u8, after_scheme, "/") orelse after_scheme.len;
    const origin = base_url[0 .. scheme_end + 3 + host_end]; // e.g., "https://cdn.jsdelivr.net"

    if (std.mem.startsWith(u8, relative, "/")) {
        // Absolute path from origin: /npm/... -> https://cdn.jsdelivr.net/npm/...
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, relative });
    } else if (std.mem.startsWith(u8, relative, "../") or std.mem.startsWith(u8, relative, "./")) {
        // Relative path: resolve against base path
        const base_path = after_scheme[host_end..]; // e.g., /npm/react-dom@18.2.0/+esm
        const base_dir = std.fs.path.dirname(base_path) orelse "/";

        // Use path resolution with fake root
        const resolved = try std.fs.path.resolve(allocator, &.{ "/", base_dir, relative });
        defer allocator.free(resolved);

        return std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, resolved });
    } else {
        // Bare relative path (no leading /): resolve against base directory
        // e.g., "npm/react@18.2.0/+esm" relative to "/npm/react-dom@18.2.0/+esm"
        // -> "/npm/react@18.2.0/+esm" (replace last segment)
        const base_path = after_scheme[host_end..];
        const base_dir = std.fs.path.dirname(base_path) orelse "/";

        return std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ origin, base_dir, relative });
    }
}

/// [Normalizer] Resolves import paths logically WITHOUT touching the filesystem.
/// Prevents '..' from escaping the sandbox root.
/// Supports import maps for bare specifier resolution.
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

    // [IMPORT MAP] Check if this is a bare specifier with a mapping
    if (sandbox.import_map.resolve(name_slice)) |mapped_url| {
        z.print("[Zig] Import map: {s} -> {s}\n", .{ name_slice, mapped_url });
        return qjs.js_strndup(ctx, mapped_url.ptr, mapped_url.len);
    }

    if (isRemote(name_slice)) {
        return z.qjs.js_strdup(ctx, module_name);
    }

    // [URL RESOLUTION] Handle relative imports within remote modules
    // When base is remote (e.g., https://cdn.jsdelivr.net/npm/react-dom@18.2.0/+esm)
    // and import is relative (e.g., npm/react@18.2.0/+esm or ../react/+esm)
    // resolve it as a URL relative to the base
    if (module_base_name) |base| {
        const base_span = std.mem.span(base);
        if (isRemote(base_span)) {
            // Parse base URL to get origin + path
            const resolved_url = resolveRemoteUrl(allocator, base_span, name_slice) catch {
                _ = qjs.JS_ThrowReferenceError(ctx, "Failed to resolve relative URL");
                return null;
            };
            std.debug.print("{s}\n", .{resolved_url});
            defer allocator.free(resolved_url);
            return qjs.js_strndup(ctx, resolved_url.ptr, resolved_url.len);
        }
    }

    // 1. Block basic nonsense (protocol-relative URLs)
    if (std.mem.startsWith(u8, name_slice, "//")) {
        _ = qjs.JS_ThrowReferenceError(ctx, "Protocol-relative imports blocked");
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
        // [SECURITY] Enforce HTTPS-only for remote imports
        if (!std.mem.startsWith(u8, name, "https://")) {
            _ = qjs.JS_ThrowReferenceError(ctx, "Security: Remote imports must use HTTPS");
            return null;
        }

        // Allocate CA bundle for TLS certificate validation
        var ca_bundle = curl.allocCABundle(allocator) catch {
            _ = qjs.JS_ThrowInternalError(ctx, "Failed to allocate CA bundle");
            return null;
        };
        defer ca_bundle.deinit();

        // Create curl Easy handle with TLS validation
        var easy = curl.Easy.init(.{ .ca_bundle = ca_bundle }) catch {
            _ = qjs.JS_ThrowInternalError(ctx, "Failed to initialize HTTP client");
            return null;
        };
        defer easy.deinit();

        // Set URL
        const url_z = allocator.dupeZ(u8, name) catch {
            _ = qjs.JS_ThrowInternalError(ctx, "Out of memory");
            return null;
        };
        defer allocator.free(url_z);
        easy.setUrl(url_z) catch {
            _ = qjs.JS_ThrowInternalError(ctx, "Failed to set URL");
            return null;
        };
        z.hardenEasy(easy);

        // GET method (default)
        easy.setMethod(.GET) catch {};

        // Setup write callback to collect response
        const WriteCtx = struct {
            list: std.ArrayList(u8),
            alloc: std.mem.Allocator,
        };
        var write_ctx = WriteCtx{ .list = .empty, .alloc = allocator };
        defer write_ctx.list.deinit(allocator);

        easy.setWritedata(&write_ctx) catch {};
        easy.setWritefunction(struct {
            fn callback(
                ptr: [*c]c_char,
                size: c_uint,
                nmemb: c_uint,
                user_data: *anyopaque,
            ) callconv(.c) c_uint {
                const total = size * nmemb;
                const wctx: *WriteCtx = @ptrCast(@alignCast(user_data));
                // Early abort: 5MB limit for remote modules (don't wait until post-download check)
                if (wctx.list.items.len + total > 5 * 1024 * 1024) return 0;
                const data: [*]const u8 = @ptrCast(ptr);
                wctx.list.appendSlice(wctx.alloc, data[0..total]) catch return 0;
                return total;
            }
        }.callback) catch {};

        // Perform synchronous fetch
        const response = easy.perform() catch {
            _ = qjs.JS_ThrowReferenceError(ctx, "Network request failed for: %s", module_name);
            return null;
        };

        // Check HTTP status
        const status = response.status_code;
        if (status < 200 or status >= 300) {
            _ = qjs.JS_ThrowReferenceError(ctx, "HTTP %d for: %s", @as(c_int, @intCast(status)), module_name);
            return null;
        }

        const code_len = write_ctx.list.items.len;
        if (code_len == 0) {
            _ = qjs.JS_ThrowReferenceError(ctx, "Empty response from: %s", module_name);
            return null;
        }

        // [SECURITY] Size limit for remote modules
        const MAX_REMOTE_SIZE = 5 * 1024 * 1024; // 5MB
        if (code_len > MAX_REMOTE_SIZE) {
            _ = qjs.JS_ThrowInternalError(ctx, "Remote module too large");
            return null;
        }

        // [SECURITY] Verify SRI hash if configured
        if (!sandbox.import_map.verifyIntegrity(name, write_ctx.list.items)) {
            _ = qjs.JS_ThrowReferenceError(ctx, "Integrity check failed for: %s", module_name);
            return null;
        }

        // Ensure null termination for QuickJS (prevents buffer overrun issues)
        write_ctx.list.append(allocator, 0) catch {
            _ = qjs.JS_ThrowInternalError(ctx, "Out of memory");
            return null;
        };

        const func_val = qjs.JS_Eval(
            ctx,
            write_ctx.list.items.ptr,
            code_len, // Original length (without null terminator)
            module_name,
            qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY,
        );

        if (qjs.JS_IsException(func_val)) {
            // Get and print the exception for debugging
            const exception = qjs.JS_GetException(ctx);
            defer qjs.JS_FreeValue(ctx, exception);

            // Print exception details
            const w_ctx = zqjs.Context.from(ctx);
            _ = w_ctx.checkAndPrintException();
            return null;
        }
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
/// - Absolute paths must start with the CWD followed by '/' or be exactly CWD.
/// - Relative paths must not start with ".." (upward traversal).
pub fn isSafePath(allocator: std.mem.Allocator, resolved_path: []const u8) bool {
    // 1. Absolute Path Check (Standard LFI protection)
    if (std.fs.path.isAbsolute(resolved_path)) {
        // We get CWD every time to ensure we aren't using a stale cached path
        const cwd = std.process.getCwdAlloc(allocator) catch return false;
        defer allocator.free(cwd);

        // [FIX] Ensure exact prefix match with separator
        // Without this, "/home/user/sandbox_evil" would pass check for "/home/user/sandbox"
        if (!std.mem.startsWith(u8, resolved_path, cwd)) return false;

        // Must be exactly cwd OR cwd followed by '/'
        if (resolved_path.len == cwd.len) return true;
        return resolved_path[cwd.len] == '/';
    }

    // 2. Relative Path Check (For systems returning relative paths from resolve)
    // We only block if it explicitly tries to traverse UP ("..")
    // "js/app.js" -> Safe.   "../etc/passwd" -> Unsafe.
    // Note: 'resolve' usually collapses inner "..", so checking the prefix is sufficient.
    return !std.mem.startsWith(u8, resolved_path, "..");
}

// =============================================================================
// Security Tests
// =============================================================================

const testing = std.testing;

/// Create a minimal QuickJS runtime+context for tests that need js_strndup / JS_Throw.
/// Caller must call deinitTestCtx when done.
fn initTestCtx() struct { rt: *qjs.JSRuntime, ctx: ?*qjs.JSContext } {
    const rt = qjs.JS_NewRuntime().?;
    const ctx = qjs.JS_NewContext(rt);
    return .{ .rt = rt, .ctx = ctx };
}
fn deinitTestCtx(t: anytype) void {
    if (t.ctx) |c| qjs.JS_FreeContext(c);
    qjs.JS_FreeRuntime(t.rt);
}

// ---------------------------------------------------------------------------
// isSafePath: relative path validation
// ---------------------------------------------------------------------------

test "isSafePath: relative safe paths" {
    const alloc = testing.allocator;
    try testing.expect(isSafePath(alloc, "js/app.js"));
    try testing.expect(isSafePath(alloc, "subdir/./file.js"));
    try testing.expect(isSafePath(alloc, "a/b/c.js"));
    try testing.expect(isSafePath(alloc, "file.js"));
}

test "isSafePath: relative traversal blocked" {
    const alloc = testing.allocator;
    try testing.expect(!isSafePath(alloc, "../evil.js"));
    try testing.expect(!isSafePath(alloc, "../../etc/passwd"));
    try testing.expect(!isSafePath(alloc, ".././.././evil.js"));
    try testing.expect(!isSafePath(alloc, "../../../root/.ssh/id_rsa"));
}

test "isSafePath: absolute path outside cwd blocked" {
    const alloc = testing.allocator;
    try testing.expect(!isSafePath(alloc, "/etc/passwd"));
    try testing.expect(!isSafePath(alloc, "/tmp/evil.js"));
    try testing.expect(!isSafePath(alloc, "/root/.ssh/id_rsa"));
}

test "isSafePath: absolute path must match cwd exactly with separator" {
    const alloc = testing.allocator;
    // Get the real CWD
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);

    // Exact CWD is safe
    try testing.expect(isSafePath(alloc, cwd));

    // CWD + /subdir is safe
    const safe = try std.fmt.allocPrint(alloc, "{s}/subdir/file.js", .{cwd});
    defer alloc.free(safe);
    try testing.expect(isSafePath(alloc, safe));

    // CWD prefix without separator is NOT safe (sandbox_evil attack)
    const evil = try std.fmt.allocPrint(alloc, "{s}_evil/file.js", .{cwd});
    defer alloc.free(evil);
    try testing.expect(!isSafePath(alloc, evil));
}

// ---------------------------------------------------------------------------
// SSRF: isBlockedUrl (tests the public API from root.zig / curl_multi.zig)
// ---------------------------------------------------------------------------

test "SSRF: localhost blocked" {
    try testing.expect(z.isBlockedUrl("http://localhost/admin"));
    try testing.expect(z.isBlockedUrl("http://localhost:8080/api"));
    try testing.expect(z.isBlockedUrl("https://localhost/secret"));
}

test "SSRF: loopback IPs blocked" {
    try testing.expect(z.isBlockedUrl("http://127.0.0.1/"));
    try testing.expect(z.isBlockedUrl("http://127.0.0.255:9090/api"));
    try testing.expect(z.isBlockedUrl("http://0.0.0.0/"));
}

test "SSRF: IPv6 loopback blocked" {
    try testing.expect(z.isBlockedUrl("http://[::1]/admin"));
    // Note: non-bracketed "http://::1/admin" is not a valid URL (: is ambiguous),
    // so extractHost cannot parse it. Only bracketed [::1] is standard in URLs.
}

test "SSRF: private networks blocked" {
    // Class A private
    try testing.expect(z.isBlockedUrl("http://10.0.0.1/"));
    try testing.expect(z.isBlockedUrl("http://10.255.255.255/"));
    // Class C private
    try testing.expect(z.isBlockedUrl("http://192.168.1.1/"));
    try testing.expect(z.isBlockedUrl("http://192.168.0.100:3000/"));
    // Class B private (172.16-31)
    try testing.expect(z.isBlockedUrl("http://172.16.0.1/"));
    try testing.expect(z.isBlockedUrl("http://172.31.255.255/"));
    // Link-local / cloud metadata
    try testing.expect(z.isBlockedUrl("http://169.254.169.254/latest/meta-data/"));
}

test "SSRF: 172.x outside private range allowed" {
    try testing.expect(!z.isBlockedUrl("http://172.15.0.1/"));
    try testing.expect(!z.isBlockedUrl("http://172.32.0.1/"));
}

test "SSRF: public URLs allowed" {
    try testing.expect(!z.isBlockedUrl("https://example.com/api"));
    try testing.expect(!z.isBlockedUrl("https://cdn.jsdelivr.net/npm/solid-js"));
    try testing.expect(!z.isBlockedUrl("http://8.8.8.8/"));
}

// ---------------------------------------------------------------------------
// Sandbox: openFileNoSymlinkEscape
// ---------------------------------------------------------------------------

test "Sandbox: open file inside sandbox" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    // build.zig exists in the project root — should be accessible
    const file = try openFileNoSymlinkEscape(&sandbox, "build.zig");
    file.close();
}

test "Sandbox: traversal with .. blocked" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    const result = openFileNoSymlinkEscape(&sandbox, "../../../etc/passwd");
    try testing.expectError(error.AccessDenied, result);
}

test "Sandbox: dot-dot in middle of path blocked" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    const result = openFileNoSymlinkEscape(&sandbox, "src/../../etc/passwd");
    try testing.expectError(error.AccessDenied, result);
}

test "Sandbox: nonexistent file returns FileNotFound" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    const result = openFileNoSymlinkEscape(&sandbox, "definitely_nonexistent_file_xyz.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "Sandbox: nested path inside sandbox works" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    // src/root.zig should exist
    const file = try openFileNoSymlinkEscape(&sandbox, "src/root.zig");
    file.close();
}

// ---------------------------------------------------------------------------
// Module normalize: path escape prevention via ScriptEngine context
// ---------------------------------------------------------------------------

test "module normalize: safe relative path resolves" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    const t = initTestCtx();
    defer deinitTestCtx(t);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    // Simulate: from "src/app.js" importing "./utils.js" → should resolve to "src/utils.js"
    const result = js_secure_module_normalize(t.ctx, "src/app.js", "./utils.js", @ptrCast(&sandbox));
    try testing.expect(result != null);
    if (result) |r| {
        const resolved = std.mem.span(r);
        try testing.expectEqualStrings("src/utils.js", resolved);
    }
}

test "module normalize: protocol-relative URL blocked" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    const t = initTestCtx();
    defer deinitTestCtx(t);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    // "//evil.com/malware.js" should be blocked (protocol-relative) → returns null
    const result = js_secure_module_normalize(t.ctx, "app.js", "//evil.com/malware.js", @ptrCast(&sandbox));
    try testing.expect(result == null);
}

test "module normalize: remote HTTPS URL passes through" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    const t = initTestCtx();
    defer deinitTestCtx(t);

    var sandbox = try Sandbox.init(alloc, cwd);
    defer sandbox.deinit();

    const result = js_secure_module_normalize(t.ctx, "app.js", "https://cdn.example.com/lib.js", @ptrCast(&sandbox));
    try testing.expect(result != null);
    if (result) |r| {
        const resolved = std.mem.span(r);
        try testing.expectEqualStrings("https://cdn.example.com/lib.js", resolved);
    }
}

// // ---------------------------------------------------------------------------
// // Module loader: end-to-end via ScriptEngine (needs full runtime)
// // ---------------------------------------------------------------------------

test "module loader: import traversal escape blocked" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var engine = try ScriptEngine.init(alloc, cwd);
    defer engine.deinit();

    // Try to import a module that escapes the sandbox via ../
    // This should fail at the normalize step (.. blocked) or loader step
    const script =
        \\import * as evil from "../../../etc/passwd";
    ;

    const val = engine.eval(script, "<escape-test>", .module);
    // Should fail — either normalize returns null or loader returns null
    try testing.expect(val == error.EvalError or val == error.JSException);
}

test "module loader: nonexistent local module fails gracefully" {
    const alloc = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    var engine = try ScriptEngine.init(alloc, cwd);
    defer engine.deinit();

    const script =
        \\import * as m from "./nonexistent_module_xyz.js";
    ;

    const val = engine.eval(script, "<missing-module>", .module);
    try testing.expect(val == error.EvalError or val == error.JSException);
}
