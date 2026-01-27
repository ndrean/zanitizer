const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

threadlocal var blob_class_id: zqjs.ClassID = 0;
threadlocal var formdata_class_id: zqjs.ClassID = 0;

// -------------------------------------------------------------------------
// BLOB
// -------------------------------------------------------------------------

pub const Blob = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    data: []u8,
    mime_type: []u8,

    pub fn deinit(self: *Blob) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }
};

fn js_Blob_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

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

    const blob = rc.allocator.create(Blob) catch return ctx.throwOutOfMemory();
    blob.parent_allocator = rc.allocator;
    blob.arena = std.heap.ArenaAllocator.init(rc.allocator);
    const arena_alloc = blob.arena.allocator();

    blob.data = arena_alloc.dupe(u8, parts_list.items) catch {
        blob.deinit();
        return ctx.throwOutOfMemory();
    };

    blob.mime_type = "";
    if (argc > 1 and ctx.isObject(argv[1])) {
        const type_val = ctx.getPropertyStr(argv[1], "type");
        defer ctx.freeValue(type_val);
        if (!ctx.isUndefined(type_val)) {
            const raw = ctx.toZString(type_val) catch "";
            defer ctx.freeZString(raw);
            blob.mime_type = arena_alloc.dupe(u8, raw) catch {
                blob.deinit();
                return ctx.throwOutOfMemory();
            };
        }
    }

    const proto = ctx.getClassProto(rc.classes.blob);
    defer ctx.freeValue(proto); // [FIX] Free local ref (+1 from getClassProto)

    const obj = ctx.newObjectProtoClass(proto, rc.classes.blob);
    _ = qjs.JS_SetOpaque(obj, blob);
    return obj;
}

fn js_Blob_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const ptr = qjs.JS_GetOpaque(val, blob_class_id);
    if (ptr) |p| {
        const self: *Blob = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

// -------------------------------------------------------------------------
// FORMDATA
// -------------------------------------------------------------------------

const FormDataEntry = struct {
    name: []u8,
    value: []u8,
    filename: ?[]u8 = null,
    mime_type: ?[]u8 = null,
};

pub const FormData = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(FormDataEntry),

    pub fn init(allocator: std.mem.Allocator) *FormData {
        const self = allocator.create(FormData) catch @panic("OOM");
        self.* = .{
            .parent_allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = .empty,
        };
        return self;
    }

    pub fn deinit(self: *FormData) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }
};

fn js_FormData_constructor(ctx_ptr: ?*qjs.JSContext, _: qjs.JSValue, _: c_int, _: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);
    const fd = FormData.init(rc.allocator);

    const proto = ctx.getClassProto(rc.classes.form_data);
    defer ctx.freeValue(proto); // [FIX] Free local ref

    const obj = ctx.newObjectProtoClass(proto, rc.classes.form_data);
    _ = qjs.JS_SetOpaque(obj, fd);
    return obj;
}

fn js_FormData_append(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 2) return ctx.throwTypeError("append requires name and value");

    const ptr = qjs.JS_GetOpaque(this, rc.classes.form_data);
    if (ptr == null) return ctx.throwTypeError("Not a FormData object");
    const fd: *FormData = @ptrCast(@alignCast(ptr));

    const arena = fd.arena.allocator();

    const name_str = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeZString(name_str);
    const name_owned = arena.dupe(u8, name_str) catch return ctx.throwOutOfMemory();

    const blob_ptr = qjs.JS_GetOpaque(argv[1], rc.classes.blob);

    if (blob_ptr) |bp| {
        const blob: *Blob = @ptrCast(@alignCast(bp));
        var filename: ?[]u8 = null;
        if (argc > 2) {
            const f_str = ctx.toZString(argv[2]) catch return ctx.throwOutOfMemory();
            defer ctx.freeZString(f_str);
            filename = arena.dupe(u8, f_str) catch return ctx.throwOutOfMemory();
        } else {
            filename = arena.dupe(u8, "blob") catch return ctx.throwOutOfMemory();
        }

        const data_copy = arena.dupe(u8, blob.data) catch return ctx.throwOutOfMemory();
        const mime_copy = arena.dupe(u8, blob.mime_type) catch return ctx.throwOutOfMemory();

        fd.entries.append(arena, .{
            .name = name_owned,
            .value = data_copy,
            .filename = filename,
            .mime_type = mime_copy,
        }) catch return ctx.throwOutOfMemory();
    } else {
        const val_str = ctx.toZString(argv[1]) catch return ctx.throwOutOfMemory();
        defer ctx.freeZString(val_str);
        const val_owned = arena.dupe(u8, val_str) catch return ctx.throwOutOfMemory();

        fd.entries.append(arena, .{
            .name = name_owned,
            .value = val_owned,
            .filename = null,
            .mime_type = null,
        }) catch return ctx.throwOutOfMemory();
    }

    return zqjs.UNDEFINED;
}

fn js_FormData_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const ptr = qjs.JS_GetOpaque(val, formdata_class_id);
    if (ptr) |p| {
        const self: *FormData = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

pub const WebDataBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();

        if (rc.classes.blob == 0) {
            rc.classes.blob = rt.newClassID();
            blob_class_id = rc.classes.blob;
            try rt.newClass(rc.classes.blob, .{ .class_name = "Blob", .finalizer = js_Blob_finalizer });
        }
        const blob_proto = ctx.newObject();
        // [FIX] DO NOT FREE blob_proto here. setClassProto TAKES OWNERSHIP.

        const blob_ctor = ctx.newCFunctionConstructor(js_Blob_constructor, "Blob", 2);

        _ = try ctx.setPropertyStr(blob_ctor, "prototype", ctx.dupValue(blob_proto));
        _ = try ctx.setPropertyStr(blob_proto, "constructor", ctx.dupValue(blob_ctor));

        ctx.setClassProto(rc.classes.blob, blob_proto);

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);
        _ = try ctx.setPropertyStr(global, "Blob", blob_ctor);

        if (rc.classes.form_data == 0) {
            rc.classes.form_data = rt.newClassID();
            formdata_class_id = rc.classes.form_data;
            try rt.newClass(rc.classes.form_data, .{ .class_name = "FormData", .finalizer = js_FormData_finalizer });
        }
        const fd_proto = ctx.newObject();
        // [FIX] DO NOT FREE fd_proto here. setClassProto TAKES OWNERSHIP.

        const fd_append = ctx.newCFunction(js_FormData_append, "append", 2);
        _ = try ctx.setPropertyStr(fd_proto, "append", fd_append);

        const fd_ctor = ctx.newCFunctionConstructor(js_FormData_constructor, "FormData", 0);

        _ = try ctx.setPropertyStr(fd_ctor, "prototype", ctx.dupValue(fd_proto));
        _ = try ctx.setPropertyStr(fd_proto, "constructor", ctx.dupValue(fd_ctor));
        ctx.setClassProto(rc.classes.form_data, fd_proto);

        _ = try ctx.setPropertyStr(global, "FormData", fd_ctor);
    }
};

pub fn serializeFormData(allocator: std.mem.Allocator, fd: *FormData) !struct { body: []u8, boundary: []u8 } {
    const boundary = try std.fmt.allocPrint(allocator, "----ZigQuickJSBoundary{d}", .{std.time.nanoTimestamp()});
    errdefer allocator.free(boundary);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);

    for (fd.entries.items) |entry| {
        try body.appendSlice(allocator, "--");
        try body.appendSlice(allocator, boundary);
        try body.appendSlice(allocator, "\r\n");

        if (entry.filename) |fname| {
            const cd = try std.fmt.allocPrint(allocator, "Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n", .{ entry.name, fname });
            defer allocator.free(cd);
            try body.appendSlice(allocator, cd);

            if (entry.mime_type) |mt| {
                const ct = try std.fmt.allocPrint(allocator, "Content-Type: {s}\r\n", .{mt});
                defer allocator.free(ct);
                try body.appendSlice(allocator, ct);
            } else {
                try body.appendSlice(allocator, "Content-Type: application/octet-stream\r\n");
            }
            try body.appendSlice(allocator, "\r\n");
            try body.appendSlice(allocator, entry.value);
        } else {
            const cd = try std.fmt.allocPrint(allocator, "Content-Disposition: form-data; name=\"{s}\"\r\n\r\n", .{entry.name});
            defer allocator.free(cd);
            try body.appendSlice(allocator, cd);
            try body.appendSlice(allocator, entry.value);
        }
        try body.appendSlice(allocator, "\r\n");
    }

    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "--\r\n");

    return .{
        .body = try body.toOwnedSlice(allocator),
        .boundary = boundary,
    };
}
