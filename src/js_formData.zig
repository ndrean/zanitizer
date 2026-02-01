const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;
const RuntimeContext = @import("runtime_context.zig").RuntimeContext;
const BlobObject = @import("js_blob.zig").BlobObject;
const js_blob = @import("js_blob.zig");
const js_file = @import("js_file.zig");

const FormDataEntry = struct {
    name: []u8,
    /// In-memory data (for Blobs/strings)
    value: []u8,
    /// File path for disk streaming (zero-copy uploads)
    file_path: ?[]u8 = null,
    filename: ?[]u8 = null,
    mime_type: ?[]u8 = null,
};

pub const FormData = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(FormDataEntry), // can get duplicates...

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
        self.entries.deinit(self.parent_allocator);
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

// fn js_FormData_append(ctx_ptr: ?*qjs.JSContext, this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
//     const ctx = zqjs.Context{ .ptr = ctx_ptr };
//     const rc = RuntimeContext.get(ctx);

//     if (argc < 2) return ctx.throwTypeError("append requires name and value");

//     const ptr = qjs.JS_GetOpaque(this, rc.classes.form_data);
//     if (ptr == null) return ctx.throwTypeError("Not a FormData object");
//     const fd: *FormData = @ptrCast(@alignCast(ptr));

//     const arena = fd.arena.allocator();

//     const name_str = ctx.toZString(argv[0]) catch return ctx.throwOutOfMemory();
//     defer ctx.freeZString(name_str);
//     const name_owned = arena.dupe(u8, name_str) catch return ctx.throwOutOfMemory();

//     const val_js = argv[1];

//     // Check if File
//     if (qjs.JS_GetOpaque(val_js, rc.classes.file)) |p| {
//         const file: *js_file.FileObject = @ptrCast(@alignCast(p));
//         const blob = &file.blob;

//         var filename: ?[]u8 = null;
//         if (argc > 2) {
//             // Explicit filename override
//             const f_str = ctx.toZString(argv[2]) catch return ctx.throwOutOfMemory();
//             defer ctx.freeZString(f_str);
//             filename = arena.dupe(u8, f_str) catch return ctx.throwOutOfMemory();
//         } else {
//             // Default to File.name
//             filename = arena.dupe(u8, file.name) catch return ctx.throwOutOfMemory();
//         }

//         const mime_copy = arena.dupe(u8, blob.mime_type) catch return ctx.throwOutOfMemory();

//         // If file has a path, use disk streaming (zero-copy for large files)
//         if (file.path) |path| {
//             const path_copy = arena.dupe(u8, path) catch return ctx.throwOutOfMemory();
//             fd.entries.append(arena, .{
//                 .name = name_owned,
//                 .value = &.{}, // empty - will use file_path instead
//                 .file_path = path_copy,
//                 .filename = filename,
//                 .mime_type = mime_copy,
//             }) catch return ctx.throwOutOfMemory();
//         } else {
//             // In-memory File (created from Blob/array) - copy data
//             const data_copy = arena.dupe(u8, blob.data) catch return ctx.throwOutOfMemory();
//             fd.entries.append(arena, .{
//                 .name = name_owned,
//                 .value = data_copy,
//                 .file_path = null,
//                 .filename = filename,
//                 .mime_type = mime_copy,
//             }) catch return ctx.throwOutOfMemory();
//         }
//     }
//     // Check if Blob (always in-memory, no file path)
//     else if (ctx.getOpaque(val_js, rc.classes.blob)) |p| {
//         const blob: *BlobObject = @ptrCast(@alignCast(p));

//         var filename: ?[]u8 = null;
//         if (argc > 2) {
//             const f_str = ctx.toZString(argv[2]) catch return ctx.throwOutOfMemory();
//             defer ctx.freeZString(f_str);
//             filename = arena.dupe(u8, f_str) catch return ctx.throwOutOfMemory();
//         } else {
//             // Blob default
//             filename = arena.dupe(u8, "blob") catch return ctx.throwOutOfMemory();
//         }

//         const data_copy = arena.dupe(u8, blob.data) catch return ctx.throwOutOfMemory();
//         const mime_copy = arena.dupe(u8, blob.mime_type) catch return ctx.throwOutOfMemory();

//         fd.entries.append(arena, .{
//             .name = name_owned,
//             .value = data_copy,
//             .file_path = null,
//             .filename = filename,
//             .mime_type = mime_copy,
//         }) catch return ctx.throwOutOfMemory();
//     } // Default String
//     else {
//         const val_str = ctx.toZString(argv[1]) catch return ctx.throwOutOfMemory();
//         defer ctx.freeZString(val_str);
//         const val_owned = arena.dupe(u8, val_str) catch return ctx.throwOutOfMemory();

//         fd.entries.append(arena, .{
//             .name = name_owned,
//             .value = val_owned,
//             .file_path = null,
//             .filename = null,
//             .mime_type = null,
//         }) catch return ctx.throwOutOfMemory();
//     }

//     return zqjs.UNDEFINED;
// }

fn js_FormData_append(ctx_ptr: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context{ .ptr = ctx_ptr };
    const rc = RuntimeContext.get(ctx);

    if (argc < 2) return ctx.throwTypeError("append requires at least 2 arguments");

    // 1. Unwrap 'this'
    const fd_ptr = qjs.JS_GetOpaque(this_val, rc.classes.form_data);
    if (fd_ptr == null) return ctx.throwTypeError("Not a FormData object");
    const self: *FormData = @ptrCast(@alignCast(fd_ptr));

    // 2. Get Name
    const name_c = ctx.toCString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeCString(name_c);
    const name = self.arena.allocator().dupe(u8, std.mem.span(name_c)) catch return ctx.throwOutOfMemory();

    const value_val = argv[1];
    var value_bytes: []u8 = &.{};
    var filename: ?[]u8 = null;
    var mime_type: ?[]u8 = null;
    var file_path: ?[]u8 = null;

    const val_class_id = qjs.JS_GetClassID(value_val);
    std.debug.print("\n[FormData] Appending '{s}'\n", .{name});
    std.debug.print("  > Value Class ID: {d}\n", .{val_class_id});
    std.debug.print("  > Expected File ID: {d}\n", .{rc.classes.file});
    std.debug.print("  > Expected Blob ID: {d}\n", .{rc.classes.blob});

    // 3. Check for File Object
    if (qjs.JS_GetOpaque(value_val, rc.classes.file)) |ptr| {
        std.debug.print("  > ✅ Detected as FILE\n", .{});
        const file: *js_file.FileObject = @ptrCast(@alignCast(ptr));

        // If it has a path (from fs.fileFromPath), use it for Zero-Copy
        if (file.path) |p| {
            file_path = self.arena.allocator().dupe(u8, p) catch return ctx.throwOutOfMemory();
        } else {
            // Otherwise use in-memory data
            value_bytes = self.arena.allocator().dupe(u8, file.blob.data) catch return ctx.throwOutOfMemory();
        }

        filename = self.arena.allocator().dupe(u8, file.name) catch return ctx.throwOutOfMemory();
        mime_type = self.arena.allocator().dupe(u8, file.blob.mime_type) catch return ctx.throwOutOfMemory();

        // 4. Check for Blob Object
    } else if (qjs.JS_GetOpaque(value_val, rc.classes.blob)) |ptr| {
        std.debug.print("  > ✅ Detected as BLOB\n", .{});
        const blob: *js_blob.BlobObject = @ptrCast(@alignCast(ptr));

        value_bytes = self.arena.allocator().dupe(u8, blob.data) catch return ctx.throwOutOfMemory();
        mime_type = self.arena.allocator().dupe(u8, blob.mime_type) catch return ctx.throwOutOfMemory();

        // Default filename for Blobs is required for httpbin to see it as a file
        filename = self.arena.allocator().dupe(u8, "blob") catch return ctx.throwOutOfMemory();

        // 5. Fallback to String
    } else {
        std.debug.print("  > ⚠️ Fallback to STRING (Opaque check failed)\n", .{});
        const str_c = ctx.toCString(value_val) catch return zqjs.EXCEPTION;
        defer ctx.freeCString(str_c);
        value_bytes = self.arena.allocator().dupe(u8, std.mem.span(str_c)) catch return ctx.throwOutOfMemory();
    }

    // 6. Explicit Filename Override (3rd argument)
    if (argc > 2 and !ctx.isUndefined(argv[2])) {
        const fn_c = ctx.toCString(argv[2]) catch return zqjs.EXCEPTION;
        defer ctx.freeCString(fn_c);

        // Overwrite whatever we found earlier
        filename = self.arena.allocator().dupe(u8, std.mem.span(fn_c)) catch return ctx.throwOutOfMemory();
    }

    // 7. Store in the list
    self.entries.append(self.parent_allocator, .{
        .name = name,
        .value = value_bytes,
        .file_path = file_path,
        .filename = filename,
        .mime_type = mime_type,
    }) catch return ctx.throwOutOfMemory();

    return zqjs.UNDEFINED;
}

fn js_FormData_finalizer(_: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    const obj_class_id = qjs.JS_GetClassID(val);
    const ptr = qjs.JS_GetOpaque(val, obj_class_id);
    if (ptr) |p| {
        const self: *FormData = @ptrCast(@alignCast(p));
        self.deinit();
    }
}

pub const FormDataBridge = struct {
    pub fn install(ctx: zqjs.Context) !void {
        const rc = RuntimeContext.get(ctx);
        const rt = ctx.getRuntime();

        const global = ctx.getGlobalObject();
        defer ctx.freeValue(global);

        if (rc.classes.form_data == 0) {
            rc.classes.form_data = rt.newClassID();
            try rt.newClass(rc.classes.form_data, .{ .class_name = "FormData", .finalizer = js_FormData_finalizer });
        }
        const fd_proto = ctx.newObject();
        // !!! DO NOT FREE fd_proto here. setClassProto TAKES OWNERSHIP.

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
