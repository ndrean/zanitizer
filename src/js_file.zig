const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const js_blob = @import("js_blob.zig");
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// We embed BlobObject as the first field.
// This allows unsafe casting from *FileObject to *BlobObject if needed,
// but usually we handle this via class IDs.
pub const FileObject = struct {
    blob: js_blob.BlobObject,
    name: []u8,
    last_modified: i64,
};

fn js_file_constructor(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 2) return ctx.throwTypeError("File constructor requires at least 2 arguments: (bits, name)");

    // 1. Parse Name & Args (Temporary copies, we will dupe into Arena later)
    const name_str = ctx.toZString(argv[1]) catch return z.jsException;
    defer ctx.freeZString(name_str);

    var mime_type: []const u8 = "";
    var last_modified: i64 = std.time.milliTimestamp();

    if (argc > 2 and ctx.isObject(argv[2])) {
        const opts = argv[2];
        const type_prop = ctx.getPropertyStr(opts, "type");
        defer ctx.freeValue(type_prop);
        if (!ctx.isUndefined(type_prop)) {
            if (ctx.toCString(type_prop)) |s| {
                mime_type = std.mem.span(s); // Uses wrapper buffer, must copy or use immediately
                defer ctx.freeCString(s);
            } else |_| {}
        }

        const lm_prop = ctx.getPropertyStr(opts, "lastModified");
        defer ctx.freeValue(lm_prop);
        if (!ctx.isUndefined(lm_prop)) {
            _ = qjs.JS_ToInt64(ctx.ptr, &last_modified, lm_prop);
        }
    }

    // 2. Create the Object & Arena FIRST
    const file_obj = rc.allocator.create(FileObject) catch return ctx.throwOutOfMemory();

    // Initialize the internal structures
    file_obj.blob.parent_allocator = rc.allocator;
    file_obj.blob.arena = std.heap.ArenaAllocator.init(rc.allocator);
    const arena_alloc = file_obj.blob.arena.allocator();

    // 3. Process 'bits' using the ARENA ALLOCATOR
    // This ensures 'data' belongs to the arena, making cleanup trivial.
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    // No errdefer deinit needed for buffer itself if we destroy the arena on error.

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
                        // On error, clean up the whole object
                        file_obj.blob.arena.deinit();
                        rc.allocator.destroy(file_obj);
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

    // 4. Finalize Fields (All allocated in Arena)
    file_obj.blob.data = buffer.toOwnedSlice(arena_alloc) catch {
        file_obj.blob.arena.deinit();
        rc.allocator.destroy(file_obj);
        return ctx.throwOutOfMemory();
    };

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

    // 5. Wrap in JS Object
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
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
    const ctx = w.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file);
    if (ptr == null) return w.UNDEFINED;

    const file: *FileObject = @ptrCast(@alignCast(ptr));
    // Access the embedded blob data length
    return ctx.newInt64(@intCast(file.blob.data.len));
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

    const ctor = ctx.newCFunction2(js_file_constructor, "File", 2, qjs.JS_CFUNC_constructor, 0);

    _ = ctx.setConstructor(ctor, proto);
    _ = qjs.JS_SetClassProto(ctx.ptr, rc.classes.file, proto);

    // Explicitly check for error when setting property
    if (qjs.JS_SetPropertyStr(ctx.ptr, global, "File", ctor) < 0) {
        return error.JS_Exception;
    }
}
