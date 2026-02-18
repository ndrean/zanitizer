const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const zqjs = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// ============================================================================
// Internal Logic
// ============================================================================

/// A single header entry.
const HeaderEntry = struct {
    name: []u8, // Owned, Lowercased
    value: []u8, // Owned
};

pub const HeadersObject = struct {
    arena: std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,
    entries: std.ArrayList(HeaderEntry),

    pub fn init(allocator: std.mem.Allocator) *HeadersObject {
        const self = allocator.create(HeadersObject) catch @panic("OOM");
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .parent_allocator = allocator,
            .entries = .{},
        };
        return self;
    }

    pub fn deinit(self: *HeadersObject) void {
        // No need to free individual entries - arena handles it
        self.entries.deinit(self.parent_allocator);
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }

    // Spec: "To normalize a byte sequence... lowercase it"
    fn normalizeName(self: *HeadersObject, name: []const u8) ![]u8 {
        const arena_alloc = self.arena.allocator();
        const lower = try arena_alloc.alloc(u8, name.len);
        @memcpy(lower, name);
        _ = std.ascii.lowerString(lower, lower);
        return lower;
    }

    pub fn append(self: *HeadersObject, name: []const u8, value: []const u8) !void {
        const arena_alloc = self.arena.allocator();
        const norm_name = try self.normalizeName(name);

        const val_copy = try arena_alloc.dupe(u8, value);

        try self.entries.append(self.parent_allocator, .{ .name = norm_name, .value = val_copy });
    }

    pub fn set(self: *HeadersObject, name: []const u8, value: []const u8) !void {
        // Use parent allocator for temporary lookup key
        const norm_name = try self.parent_allocator.alloc(u8, name.len);
        defer self.parent_allocator.free(norm_name);
        @memcpy(norm_name, name);
        _ = std.ascii.lowerString(norm_name, norm_name);

        // 1. Remove all existing (no need to free - arena handles it)
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].name, norm_name)) {
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // 2. Append new
        try self.append(name, value);
    }

    pub fn delete(self: *HeadersObject, name: []const u8) !void {
        // Use parent allocator for temporary lookup key
        const norm_name = try self.parent_allocator.alloc(u8, name.len);
        defer self.parent_allocator.free(norm_name);
        @memcpy(norm_name, name);
        _ = std.ascii.lowerString(norm_name, norm_name);

        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].name, norm_name)) {
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn get(self: *HeadersObject, name: []const u8) !?[]u8 {
        // Use parent allocator for temporary lookup key
        const norm_name = try self.parent_allocator.alloc(u8, name.len);
        defer self.parent_allocator.free(norm_name);
        @memcpy(norm_name, name);
        _ = std.ascii.lowerString(norm_name, norm_name);

        // Use parent_allocator for result since it's returned to caller
        var result: std.ArrayList(u8) = .{};
        defer result.deinit(self.parent_allocator);

        var found = false;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, norm_name)) {
                if (found) {
                    try result.appendSlice(self.parent_allocator, ", ");
                }
                try result.appendSlice(self.parent_allocator, entry.value);
                found = true;
            }
        }

        if (!found) return null;
        return try result.toOwnedSlice(self.parent_allocator);
    }

    pub fn has(self: *HeadersObject, name: []const u8) !bool {
        // Use parent allocator for temporary lookup key
        const norm_name = try self.parent_allocator.alloc(u8, name.len);
        defer self.parent_allocator.free(norm_name);
        @memcpy(norm_name, name);
        _ = std.ascii.lowerString(norm_name, norm_name);

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, norm_name)) return true;
        }
        return false;
    }
};

// ============================================================================
// JS Bindings
// ============================================================================

fn finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    // const ptr = qjs.JS_GetOpaque(val, class_id);
    if (ptr) |p| {
        const self: *HeadersObject = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

fn js_Headers_append(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("append requires 2 arguments");
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(HeadersObject, this, rc.classes.headers) orelse
        return ctx.throwTypeError("Not a Headers object");

    const name = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(name);
    const value = ctx.toZString(argv[1]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(value);

    self.append(name, value) catch return zqjs.EXCEPTION;
    return zqjs.UNDEFINED;
}

fn js_Headers_set(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 2) return ctx.throwTypeError("set requires 2 arguments");
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(HeadersObject, this, rc.classes.headers) orelse
        return ctx.throwTypeError("Not a Headers object");

    const name = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(name);
    const value = ctx.toZString(argv[1]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(value);

    self.set(name, value) catch return zqjs.EXCEPTION;
    return zqjs.UNDEFINED;
}

fn js_Headers_get(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("get requires 1 argument");
    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(HeadersObject, this, rc.classes.headers) orelse
        return ctx.throwTypeError("Not a Headers object");

    const name = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(name);

    const result = self.get(name) catch return zqjs.EXCEPTION;
    if (result) |str| {
        defer self.parent_allocator.free(str);
        return ctx.newString(str);
    }
    return zqjs.NULL;
}

fn js_Headers_has(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("has requires 1 argument");

    const rc = RuntimeContext.get(ctx);
    const self = ctx.getOpaqueAs(HeadersObject, this, rc.classes.headers) orelse
        return ctx.throwTypeError("Not a Headers object");

    const name = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(name);

    const found = self.has(name) catch return zqjs.EXCEPTION;
    return ctx.newBool(found);
}

fn js_Headers_delete(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    if (argc < 1) return ctx.throwTypeError("delete requires 1 argument");
    const rc = RuntimeContext.get(ctx);

    const self = ctx.getOpaqueAs(HeadersObject, this, rc.classes.headers) orelse
        return ctx.throwTypeError("Not a Headers object");

    const name = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(name);

    self.delete(name) catch return zqjs.EXCEPTION;
    return zqjs.UNDEFINED;
}

fn js_Headers_constructor(ctx_ptr: ?*qjs.JSContext, new_target: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const self = HeadersObject.init(rc.allocator);
    errdefer self.deinit();

    // Optional init: new Headers({ "Content-Type": "json" })
    if (argc > 0 and !ctx.isUndefined(argv[0])) {
        // Simple support: iterate object keys
        // (Full spec supports array of arrays too, skipping for brevity)
        const init_obj = argv[0];

        // This is a naive property iterator.
        // For production, you'd check JS_IsArray vs JS_IsObject.
        // Assuming plain object for now:
        var prop_enum: ?[*]qjs.JSPropertyEnum = undefined;
        var prop_count: u32 = 0;

        if (qjs.JS_GetOwnPropertyNames(ctx.ptr, &prop_enum, &prop_count, init_obj, qjs.JS_GPN_STRING_MASK | qjs.JS_GPN_ENUM_ONLY) == 0) {
            defer if (prop_enum) |pe| qjs.JS_FreePropertyEnum(ctx.ptr, pe, prop_count);

            if (prop_enum) |pe| {
                var i: u32 = 0;
                while (i < prop_count) : (i += 1) {
                    const atom = pe[i].atom;
                    const key_val = qjs.JS_AtomToString(ctx.ptr, atom);
                    const val_val = qjs.JS_GetProperty(ctx.ptr, init_obj, atom);

                    const key_str = ctx.toZString(key_val) catch {
                        qjs.JS_FreeValue(ctx.ptr, key_val);
                        qjs.JS_FreeValue(ctx.ptr, val_val);
                        continue;
                    };
                    const val_str = ctx.toZString(val_val) catch {
                        ctx.freeZString(key_str);
                        qjs.JS_FreeValue(ctx.ptr, key_val);
                        qjs.JS_FreeValue(ctx.ptr, val_val);
                        continue;
                    };

                    self.append(key_str, val_str) catch {}; // Ignore append errors?

                    ctx.freeZString(key_str);
                    ctx.freeZString(val_str);
                    qjs.JS_FreeValue(ctx.ptr, key_val);
                    qjs.JS_FreeValue(ctx.ptr, val_val);
                }
            }
        }
    }

    const proto = ctx.getPropertyStr(new_target, "prototype");
    defer ctx.freeValue(proto);

    const obj = ctx.newObjectProtoClass(proto, rc.classes.headers);
    if (qjs.JS_IsException(obj)) {
        self.deinit();
        return obj;
    }
    _ = qjs.JS_SetOpaque(obj, self);

    return obj;
}

// ============================================================================
// Installer
// ============================================================================

pub const HeadersBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const rt = ctx.getRuntime();
        const rc = RuntimeContext.get(ctx);

        if (rc.classes.headers == 0) {
            rc.classes.headers = rt.newClassID();
            try rt.newClass(rc.classes.headers, .{
                .class_name = "Headers",
                .finalizer = finalizer,
            });
        }

        const proto = ctx.newObject();

        try ctx.setPropertyStr(proto, "append", ctx.newCFunction(js_Headers_append, "append", 2));
        try ctx.setPropertyStr(proto, "delete", ctx.newCFunction(js_Headers_delete, "delete", 1));
        try ctx.setPropertyStr(proto, "get", ctx.newCFunction(js_Headers_get, "get", 1));
        try ctx.setPropertyStr(proto, "has", ctx.newCFunction(js_Headers_has, "has", 1));
        try ctx.setPropertyStr(proto, "set", ctx.newCFunction(js_Headers_set, "set", 2));

        const ctor = ctx.newCFunction2(js_Headers_constructor, "Headers", 0, qjs.JS_CFUNC_constructor, 0);

        ctx.setConstructor(ctor, proto);
        ctx.setClassProto(rc.classes.headers, proto);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        try ctx.setPropertyStr(global, "Headers", ctor);
    }
};
