// js_fileList.zig

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;

// Holds JSValues (Files), keeping them alive via RefCount
pub const FileList = struct {
    allocator: std.mem.Allocator,
    items: []qjs.JSValue,

    pub fn init(allocator: std.mem.Allocator, values: []const qjs.JSValue, ctx: *qjs.JSContext) *FileList {
        const self = allocator.create(FileList) catch @panic("OOM");
        self.allocator = allocator;
        self.items = allocator.alloc(qjs.JSValue, values.len) catch @panic("OOM");

        // Copy and INCREMENT REF COUNT
        for (values, 0..) |v, i| {
            self.items[i] = qjs.JS_DupValue(ctx, v);
        }
        return self;
    }

    pub fn deinit(self: *FileList, ctx: *qjs.JSContext) void {
        for (self.items) |v| {
            qjs.JS_FreeValue(ctx, v);
        }
        self.allocator.free(self.items);
        self.allocator.destroy(self);
    }
};

fn js_filelist_item(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file_list);
    if (ptr == null) return w.UNDEFINED;
    const list: *FileList = @ptrCast(@alignCast(ptr));

    var idx: u32 = 0;
    if (qjs.JS_ToUint32(ctx.ptr, &idx, argv[0]) != 0) return w.NULL;

    if (idx >= list.items.len) return w.NULL;

    // Return a new reference to the existing value
    return qjs.JS_DupValue(ctx_ptr, list.items[idx]);
}

fn js_filelist_get_length(
    ctx_ptr: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    _: c_int,
    _: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = w.Context.from(ctx_ptr);
    const rc = RuntimeContext.get(ctx);

    const ptr = qjs.JS_GetOpaque(this_val, rc.classes.file_list);
    if (ptr == null) return ctx.newInt32(0);
    const list: *FileList = @ptrCast(@alignCast(ptr));

    return ctx.newInt32(@intCast(list.items.len));
}

fn js_filelist_finalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const class_id = qjs.JS_GetClassID(val);
    if (qjs.JS_GetOpaque(val, class_id)) |ptr| {
        const list: *FileList = @ptrCast(@alignCast(ptr));
        // We need a context to free values.
        // NOTE: In finalizers, we technically don't have a context easily.
        // QuickJS allows JS_FreeValueRT(rt, val).

        for (list.items) |v| {
            qjs.JS_FreeValueRT(rt, v);
        }
        list.allocator.free(list.items);
        list.allocator.destroy(list);
    }
}

pub fn install(ctx: w.Context) !void {
    const rc = RuntimeContext.get(ctx);
    const rt = ctx.getRuntime();
    const global = ctx.getGlobalObject();
    defer ctx.freeValue(global);

    if (rc.classes.file_list == 0) {
        rc.classes.file_list = rt.newClassID();
        try rt.newClass(rc.classes.file_list, .{ .class_name = "FileList", .finalizer = js_filelist_finalizer });
    }

    const proto = ctx.newObject();

    try ctx.setPropertyStr(proto, "item", ctx.newCFunction(js_filelist_item, "item", 1));

    {
        const len_atom = ctx.newAtom("length");
        defer ctx.freeAtom(len_atom);
        const get_len = ctx.newCFunction(js_filelist_get_length, "get length", 0);
        _ = qjs.JS_DefinePropertyGetSet(ctx.ptr, proto, len_atom, get_len, w.UNDEFINED, qjs.JS_PROP_CONFIGURABLE | qjs.JS_PROP_ENUMERABLE);
    }

    // Usually FileList isn't constructible by user "new FileList()", but we can expose it if debugging.
    // For now, just register the class/proto so we can create instances from Zig.
    _ = qjs.JS_SetClassProto(ctx.ptr, rc.classes.file_list, proto);

    // We don't necessarily need to expose "FileList" constructor to Global unless you want to.
    // But `instanceof FileList` needs it.
    const ctor = ctx.newCFunction2(js_filelist_item, "FileList", 0, qjs.JS_CFUNC_constructor, 0); // Dummy ctor
    _ = ctx.setConstructor(ctor, proto);
    _ = qjs.JS_SetPropertyStr(ctx.ptr, global, "FileList", ctor);
}

// Helper to create a FileList from Zig side (e.g. for input elements)
pub fn createFileList(ctx: w.Context, files: []const qjs.JSValue) qjs.JSValue {
    const rc = RuntimeContext.get(ctx);
    const list = FileList.init(rc.allocator, files, ctx.ptr);

    const obj = qjs.JS_NewObjectClass(ctx.ptr, rc.classes.file_list);
    _ = qjs.JS_SetOpaque(obj, list);
    return obj;
}
