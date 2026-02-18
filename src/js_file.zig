const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const js_blob = @import("js_blob.zig");
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const js_security = @import("js_security.zig");

// We embed BlobObject as the first field.
// This allows unsafe casting from *FileObject to *BlobObject if needed,
// but usually we handle this via class IDs.
pub const FileObject = struct {
    blob: js_blob.BlobObject,
    name: []u8,
    last_modified: i64,
    /// Original file path for disk streaming (null for in-memory Files)
    path: ?[]u8 = null,
    /// Actual file size on disk (for disk-backed files where blob.data is empty)
    disk_size: ?u64 = null,
};

fn js_file_constructor(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (argc < 2) return ctx.throwTypeError("File constructor requires at least 2 arguments: (bits, name)");

    // 1. Parse Name
    const name_str = ctx.toZString(argv[1]) catch return z.jsException;
    defer ctx.freeZString(name_str);

    // 2. Prepare Variables for Options
    // We hold the raw C-String pointers here so we can defer their cleanup at function scope
    var type_cstr: ?[*c]const u8 = null;
    defer if (type_cstr) |s| ctx.freeCString(s);

    var path_cstr: ?[*c]const u8 = null;
    defer if (path_cstr) |s| ctx.freeCString(s);

    var mime_type: []const u8 = "";
    var last_modified: i64 = std.time.milliTimestamp();
    var file_path: ?[]const u8 = null;

    // 3. Parse Options
    if (argc > 2 and ctx.isObject(argv[2])) {
        const opts = argv[2];

        // 'type'
        const type_prop = ctx.getPropertyStr(opts, "type");
        defer ctx.freeValue(type_prop);
        if (!ctx.isUndefined(type_prop)) {
            if (ctx.toCString(type_prop)) |s| {
                type_cstr = s; // Store pointer to free later
                mime_type = std.mem.span(s);
            } else |_| {}
        }

        // 'lastModified'
        const lm_prop = ctx.getPropertyStr(opts, "lastModified");
        defer ctx.freeValue(lm_prop);
        if (!ctx.isUndefined(lm_prop)) {
            _ = qjs.JS_ToInt64(ctx.ptr, &last_modified, lm_prop);
        }

        // 'path' (Custom Extension for Zero-Copy I/O)
        const path_prop = ctx.getPropertyStr(opts, "path");
        defer ctx.freeValue(path_prop);
        if (!ctx.isUndefined(path_prop)) {
            if (ctx.toCString(path_prop)) |s| {
                path_cstr = s; // Store pointer to free later
                file_path = std.mem.span(s);
            } else |_| {}
        }
    }

    // 4. Create Object & Arena
    const file_obj = rc.allocator.create(FileObject) catch return ctx.throwOutOfMemory();
    file_obj.blob.parent_allocator = rc.allocator;
    file_obj.blob.arena = std.heap.ArenaAllocator.init(rc.allocator);
    const arena_alloc = file_obj.blob.arena.allocator();

    // Initialize defaults
    file_obj.path = null;
    file_obj.disk_size = null;

    // 5. Handle Data Source (Disk Path vs Memory Bits)
    if (file_path) |path| {
        // --- CASE A: Disk-Backed File (Zero Copy) ---

        // Verify file exists & get stats (Security Check)
        const file = js_security.openFileNoSymlinkEscape(rc.sandbox, path) catch {
            file_obj.blob.arena.deinit();
            rc.allocator.destroy(file_obj);
            return ctx.throwTypeError("File not found or access denied:");
        };
        defer file.close();

        const stat = file.stat() catch {
            file_obj.blob.arena.deinit();
            rc.allocator.destroy(file_obj);
            return ctx.throwInternalError("Failed to stat file");
        };

        // Copy path to Arena
        file_obj.path = arena_alloc.dupe(u8, path) catch {
            file_obj.blob.arena.deinit();
            rc.allocator.destroy(file_obj);
            return ctx.throwOutOfMemory();
        };

        // Set metadata
        file_obj.disk_size = stat.size;
        file_obj.blob.data = &.{}; // Empty memory buffer for Zero-Copy

    } else {
        // --- CASE B: In-Memory File (Standard Behavior) ---

        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const bits = argv[0];

        if (ctx.isArray(bits)) {
            const len_val = ctx.getPropertyStr(bits, "length");
            var len: u32 = 0;
            _ = qjs.JS_ToUint32(ctx.ptr, &len, len_val);
            ctx.freeValue(len_val);

            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const val = qjs.JS_GetPropertyUint32(ctx.ptr, bits, i);
                defer qjs.JS_FreeValue(ctx.ptr, val);

                if (ctx.isString(val)) {
                    if (ctx.toCString(val)) |s| {
                        buffer.appendSlice(arena_alloc, std.mem.span(s)) catch {
                            file_obj.blob.arena.deinit();
                            rc.allocator.destroy(file_obj);
                            ctx.freeCString(s); // Free temp string
                            return ctx.throwOutOfMemory();
                        };
                        ctx.freeCString(s);
                    } else |_| {}
                } else {
                    var ab_len: usize = 0;
                    const ptr = qjs.JS_GetArrayBuffer(ctx.ptr, &ab_len, val);
                    if (ptr != null) {
                        buffer.appendSlice(arena_alloc, ptr[0..ab_len]) catch {
                            file_obj.blob.arena.deinit();
                            rc.allocator.destroy(file_obj);
                            return ctx.throwOutOfMemory();
                        };
                    }
                }
            }
        }

        file_obj.blob.data = buffer.toOwnedSlice(arena_alloc) catch {
            file_obj.blob.arena.deinit();
            rc.allocator.destroy(file_obj);
            return ctx.throwOutOfMemory();
        };
    }

    // 6. Finalize Common Fields
    file_obj.blob.mime_type = arena_alloc.dupe(u8, mime_type) catch {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return ctx.throwOutOfMemory();
    };

    file_obj.name = arena_alloc.dupe(u8, name_str) catch {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return ctx.throwOutOfMemory();
    };

    file_obj.last_modified = last_modified;

    // 7. Return JS Object
    const obj = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.file);
    if (qjs.JS_IsException(obj)) {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return obj;
    }

    _ = qjs.JS_SetOpaque(obj, file_obj);
    return obj;
}

fn js_file_get_name(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file);
    if (ptr == null) return w.UNDEFINED;

    const file: *FileObject = @ptrCast(@alignCast(ptr));
    return ctx.newString(file.name);
}

fn js_file_get_lastModified(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file);
    if (ptr == null) return w.UNDEFINED;

    const file: *FileObject = @ptrCast(@alignCast(ptr));
    return ctx.newInt64(file.last_modified);
}

fn js_file_get_size(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file);
    if (ptr == null) return w.UNDEFINED;

    const file: *FileObject = @ptrCast(@alignCast(ptr));
    // For disk-backed files, use stored disk_size; otherwise use blob.data.len
    const size: u64 = file.disk_size orelse file.blob.data.len;
    return ctx.newInt64(@intCast(size));
}

fn js_file_get_type(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file);
    if (ptr == null) return ctx.newString("");

    const file: *FileObject = @ptrCast(@alignCast(ptr));
    return ctx.newString(file.blob.mime_type);
}

/// File.fromPath(path) - Create a File backed by a disk path (for zero-copy uploads)
/// The file is NOT loaded into memory - curl streams directly from disk
fn js_file_fromPath(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    if (argc < 1) return ctx.throwTypeError("File.fromPath requires a path argument");

    const path_str = ctx.toZString(argv[0]) catch return z.jsException;
    defer ctx.freeZString(path_str);

    // Validate path is within sandbox and get file handle for metadata
    const file = js_security.openFileNoSymlinkEscape(rc.sandbox, path_str) catch |err| {
        return switch (err) {
            error.FileNotFound => ctx.throwTypeError("File not found"),
            error.AccessDenied, error.SymLinkLoop => ctx.throwTypeError("Access denied (symlink escape attempt)"),
            else => ctx.throwInternalError("Failed to access file"),
        };
    };
    defer file.close();

    // Get file metadata
    const stat = file.stat() catch {
        return ctx.throwInternalError("Failed to get file metadata");
    };

    // Extract filename from path
    const filename = std.fs.path.basename(path_str);

    // Guess MIME type from extension
    const mime_type = guessMimeType(filename);

    // Create FileObject
    const file_obj = rc.allocator.create(FileObject) catch return ctx.throwOutOfMemory();

    file_obj.blob.parent_allocator = rc.allocator;
    file_obj.blob.arena = std.heap.ArenaAllocator.init(rc.allocator);
    const arena_alloc = file_obj.blob.arena.allocator();

    // Store path (data stays empty - curl will stream from disk)
    file_obj.blob.data = &.{}; // Empty - will use path instead
    file_obj.blob.mime_type = arena_alloc.dupe(u8, mime_type) catch {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return ctx.throwOutOfMemory();
    };

    file_obj.name = arena_alloc.dupe(u8, filename) catch {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return ctx.throwOutOfMemory();
    };

    // Store the full path for curl to stream from
    file_obj.path = arena_alloc.dupe(u8, path_str) catch {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return ctx.throwOutOfMemory();
    };

    // Convert mtime (nanoseconds since epoch) to milliseconds
    file_obj.last_modified = @intCast(@divFloor(stat.mtime, std.time.ns_per_ms));

    // Store actual file size for disk-backed files
    file_obj.disk_size = stat.size;

    // Wrap in JS Object
    const obj = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.file);
    if (qjs.JS_IsException(obj)) {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return obj;
    }

    _ = qjs.JS_SetOpaque(obj, file_obj);
    return obj;
}

/// MIME type lookup using compile-time StaticStringMap (O(1) lookup)
const mime_map = std.StaticStringMap([]const u8).initComptime(.{
    // Text
    .{ ".txt", "text/plain" },
    .{ ".html", "text/html" },
    .{ ".htm", "text/html" },
    .{ ".css", "text/css" },
    .{ ".csv", "text/csv" },
    // Application
    .{ ".js", "application/javascript" },
    .{ ".mjs", "application/javascript" },
    .{ ".json", "application/json" },
    .{ ".xml", "application/xml" },
    .{ ".pdf", "application/pdf" },
    .{ ".zip", "application/zip" },
    .{ ".gz", "application/gzip" },
    .{ ".gzip", "application/gzip" },
    .{ ".tar", "application/x-tar" },
    .{ ".wasm", "application/wasm" },
    // Images
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".webp", "image/webp" },
    .{ ".ico", "image/x-icon" },
    .{ ".bmp", "image/bmp" },
    .{ ".avif", "image/avif" },
    // Audio
    .{ ".mp3", "audio/mpeg" },
    .{ ".wav", "audio/wav" },
    .{ ".ogg", "audio/ogg" },
    .{ ".flac", "audio/flac" },
    .{ ".aac", "audio/aac" },
    // Video
    .{ ".mp4", "video/mp4" },
    .{ ".webm", "video/webm" },
    .{ ".avi", "video/x-msvideo" },
    .{ ".mov", "video/quicktime" },
    .{ ".mkv", "video/x-matroska" },
    // Fonts
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".ttf", "font/ttf" },
    .{ ".otf", "font/otf" },
});

/// Guess MIME type from filename extension (O(1) compile-time lookup)
fn guessMimeType(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    return mime_map.get(ext) orelse "application/octet-stream";
}

// Finalizer
pub fn js_file_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const class_id = qjs.JS_GetClassID(val);
    if (qjs.JS_GetOpaque(val, class_id)) |ptr| {
        const file: *FileObject = @ptrCast(@alignCast(ptr));
        const parent_alloc = file.blob.parent_allocator;

        // This frees 'data', 'mime_type', AND 'name' automatically
        file.blob.arena.deinit();

        // Finally destroy the shell
        parent_alloc.destroy(file);
    }
}

pub fn install(ctx: w.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    // Setup Class (if not already done in initialization)
    if (rc.classes.file == 0) {
        rc.classes.file = rt.newClassID();
        try rt.newClass(rc.classes.file, .{ .class_name = "File", .finalizer = js_file_finalizer });
    }

    //  Inherit from Blob
    const blob_ctor = ctx.getPropertyStr(global, "Blob");
    defer ctx.freeValue(blob_ctor);

    if (ctx.isUndefined(blob_ctor)) {
        return error.BlobNotInstalled;
    }

    const proto = ctx.newObject();
    // Inherit from Blob: File.prototype.__proto__ = Blob.prototype
    const blob_proto = ctx.getPropertyStr(blob_ctor, "prototype");
    _ = qjs.JS_SetPrototype(ctx.ptr, proto, blob_proto);
    ctx.freeValue(blob_proto);

    {
        const name_atom = ctx.newAtom("name");
        defer ctx.freeAtom(name_atom);

        // Create Getter Function
        const get_name = ctx.newCFunction(js_file_get_name, "get name", 0);

        // Define Property (Consumes get_name reference)
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, name_atom, get_name, w.UNDEFINED, // No Setter
            qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    }

    {
        const lm_atom = ctx.newAtom("lastModified");
        defer ctx.freeAtom(lm_atom);

        const get_lm = ctx.newCFunction(js_file_get_lastModified, "get lastModified", 0);

        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, lm_atom, get_lm, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    }

    {
        const size_atom = ctx.newAtom("size");
        defer ctx.freeAtom(size_atom);
        const get_size = ctx.newCFunction(js_file_get_size, "get size", 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, size_atom, get_size, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    }

    {
        const type_atom = ctx.newAtom("type");
        defer ctx.freeAtom(type_atom);
        const get_type = ctx.newCFunction(js_file_get_type, "get type", 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, type_atom, get_type, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    }

    const ctor = ctx.newCFunction2(js_file_constructor, "File", 2, qjs.JS_CFUNC_constructor, 0);

    // Add static method: File.fromPath(path)
    const from_path_fn = ctx.newCFunction(js_file_fromPath, "fromPath", 1);
    try ctx.setPropertyStr(ctor, "fromPath", from_path_fn);

    _ = ctx.setConstructor(ctor, proto);
    _ = qjs.JS_SetClassProto(ctx.ptr, rc.classes.file, proto);

    // Explicitly check for error when setting property
    if (qjs.JS_SetPropertyStr(ctx.ptr, global, "File", ctor) < 0) {
        return error.JS_Exception;
    }
}
