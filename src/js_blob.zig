//! new Blob()
//!
//! ✅ blob.text(), blob.arrayBuffer(), blob.size(); blob.json()
//!
//! ⚠️ Missing blob.slice(), blob.bytes(), blob.stream()

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// ============================================================================
// Blob Struct
// ============================================================================

pub const BlobObject = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    data: []u8,
    mime_type: []u8,

    // Helper for internal C-API creation if needed
    pub fn init(allocator: std.mem.Allocator, data: []const u8, mime: []const u8) !*BlobObject {
        const self = try allocator.create(BlobObject);
        self.parent_allocator = allocator;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        const arena_alloc = self.arena.allocator();

        self.data = try arena_alloc.dupe(u8, data);
        self.mime_type = try arena_alloc.dupe(u8, mime);

        return self;
    }

    // [FIX] Correctly destroy the Arena, which frees 'data' and 'mime_type' automatically.
    // Do NOT call parent_allocator.free(self.data) because it belongs to the Arena.
    pub fn deinit(self: *BlobObject) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }
};

// === Liefcycle
pub fn js_Blob_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    // 1. Accumulate Parts (Temporary storage)
    var parts_list: std.ArrayListUnmanaged(u8) = .empty;
    defer parts_list.deinit(rc.allocator);

    if (argc > 0 and ctx.isArray(argv[0])) {
        const arr = argv[0];
        const len_val = ctx.getPropertyStr(arr, "length");
        defer ctx.freeValue(len_val);

        var len: i64 = 0;
        _ = qjs.JS_ToInt64(ctx.ptr, &len, len_val);

        var i: i64 = 0;
        while (i < len) : (i += 1) {
            const item = ctx.getPropertyInt64(arr, i);
            defer ctx.freeValue(item);

            var size: usize = 0;
            if (qjs.JS_GetArrayBuffer(ctx.ptr, &size, item)) |ptr| {
                parts_list.appendSlice(rc.allocator, ptr[0..size]) catch break;
            } else {
                const str = ctx.toZString(item) catch continue;
                defer ctx.freeZString(str);
                parts_list.appendSlice(rc.allocator, str) catch break;
            }
        }
    }

    // 2. Allocate Blob Object
    const blob = rc.allocator.create(BlobObject) catch return ctx.throwOutOfMemory();

    // Initialize Arena
    blob.parent_allocator = rc.allocator;
    blob.arena = std.heap.ArenaAllocator.init(rc.allocator);
    const arena_alloc = blob.arena.allocator();

    // 3. Copy Data into Arena
    blob.data = arena_alloc.dupe(u8, parts_list.items) catch {
        blob.deinit();
        return ctx.throwOutOfMemory();
    };

    // 4. Process Options
    blob.mime_type = arena_alloc.dupe(u8, "") catch {
        blob.deinit();
        return ctx.throwOutOfMemory();
    };

    if (argc > 1 and ctx.isObject(argv[1])) {
        const type_val = ctx.getPropertyStr(argv[1], "type");
        defer ctx.freeValue(type_val);

        if (!ctx.isUndefined(type_val)) {
            const raw = ctx.toZString(type_val) catch "";
            defer ctx.freeZString(raw);

            // Re-allocate in arena (old empty string is negligible)
            blob.mime_type = arena_alloc.dupe(u8, raw) catch {
                blob.deinit();
                return ctx.throwOutOfMemory();
            };
        }
    }

    // 5. Wrap in JS Object
    const proto = ctx.getClassProto(rc.classes.blob);
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, rc.classes.blob);
    _ = qjs.JS_SetOpaque(obj, blob);

    return obj;
}

pub fn finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const self: *BlobObject = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

// === Methods

/// Blob.text()
pub fn js_Blob_text(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.blob);
    if (ptr == null) return ctx.throwTypeError("Not a Blob object");
    const self: *BlobObject = @ptrCast(@alignCast(ptr));

    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return zqjs.EXCEPTION;

    const resolve = resolvers[0];
    const reject = resolvers[1];

    // QuickJS JS_NewStringLen expects UTF-8.
    // For binary data (like images), this might fail or replace invalid chars.
    const str_val = ctx.newString(self.data);

    if (qjs.JS_IsException(str_val)) {
        const err = ctx.getException();
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{err});
        ctx.freeValue(err);
    } else {
        _ = ctx.call(resolve, zqjs.UNDEFINED, &.{str_val});
        ctx.freeValue(str_val);
    }

    ctx.freeValue(resolve);
    ctx.freeValue(reject);
    return promise;
}

/// Blob.arrayBuffer()
pub fn js_Blob_arrayBuffer(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this, rc.classes.blob);
    if (ptr == null) return ctx.throwTypeError("Not a Blob object");
    const self: *BlobObject = @ptrCast(@alignCast(ptr));

    var resolvers: [2]qjs.JSValue = undefined;
    const promise = qjs.JS_NewPromiseCapability(ctx.ptr, &resolvers);
    if (qjs.JS_IsException(promise)) return zqjs.EXCEPTION;

    const resolve = resolvers[0];
    const reject = resolvers[1];

    const ab = ctx.newArrayBufferCopy(self.data);
    if (qjs.JS_IsException(ab)) {
        const err = ctx.getException();
        _ = ctx.call(reject, zqjs.UNDEFINED, &.{err});
        ctx.freeValue(err);
    } else {
        _ = ctx.call(resolve, zqjs.UNDEFINED, &.{ab});
        ctx.freeValue(ab);
    }

    ctx.freeValue(resolve);
    ctx.freeValue(reject);
    return promise;
}

// === Properties

/// Accessor Blob.size
pub fn js_Blob_get_size(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this, rc.classes.blob);
    if (ptr == null) return zqjs.UNDEFINED;
    const self: *BlobObject = @ptrCast(@alignCast(ptr));
    return ctx.newInt64(@intCast(self.data.len));
}

/// Accessor Blob.type
pub fn js_Blob_get_type(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const ptr = qjs.JS_GetOpaque(this, rc.classes.blob);
    if (ptr == null) return ctx.newString("");
    const self: *BlobObject = @ptrCast(@alignCast(ptr));
    return ctx.newString(self.mime_type);
}

pub const BlobBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();

        if (rc.classes.blob == 0) {
            rc.classes.blob = rt.newClassID();
            try rt.newClass(rc.classes.blob, .{
                .class_name = "Blob",
                .finalizer = finalizer,
            });
        }

        const proto = ctx.newObject();

        // 1. Methods
        try ctx.setPropertyStr(proto, "text", ctx.newCFunction(js_Blob_text, "text", 0));
        try ctx.setPropertyStr(proto, "arrayBuffer", ctx.newCFunction(js_Blob_arrayBuffer, "arrayBuffer", 0));

        // 2. Getters
        {
            const size_atom = qjs.JS_NewAtom(ctx.ptr, "size");
            defer qjs.JS_FreeAtom(ctx.ptr, size_atom);
            const get_size = ctx.newCFunction(js_Blob_get_size, "get_size", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, size_atom, get_size, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }
        {
            const type_atom = qjs.JS_NewAtom(ctx.ptr, "type");
            defer qjs.JS_FreeAtom(ctx.ptr, type_atom);
            const get_type = ctx.newCFunction(js_Blob_get_type, "get_type", 0);
            _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, type_atom, get_type, zqjs.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
        }

        // 3. Symbol.toStringTag -> "Blob"
        {
            const global = ctx.getGlobalObject();
            defer ctx.freeValue(global);
            const symbol_ctor = ctx.getPropertyStr(global, "Symbol");
            defer ctx.freeValue(symbol_ctor);
            const tag_sym_val = ctx.getPropertyStr(symbol_ctor, "toStringTag");
            defer ctx.freeValue(tag_sym_val);
            const tag_atom = qjs.JS_ValueToAtom(ctx.ptr, tag_sym_val);
            defer qjs.JS_FreeAtom(ctx.ptr, tag_atom);

            _ = qjs.JS_DefinePropertyValue(ctx.ptr, proto, tag_atom, ctx.newString("Blob"), qjs.JS_PROP_CONFIGURABLE);
        }

        // 4. Constructor
        const ctor = ctx.newCFunctionConstructor(js_Blob_constructor, "Blob", 2);

        // Link Prototype <-> Constructor
        try ctx.setPropertyStr(ctor, "prototype", ctx.dupValue(proto));
        try ctx.setPropertyStr(proto, "constructor", ctx.dupValue(ctor));

        ctx.setClassProto(rc.classes.blob, proto);

        const global_obj = ctx.getGlobalObject();
        defer ctx.freeValue(global_obj);
        try ctx.setPropertyStr(global_obj, "Blob", ctor);
    }
};
