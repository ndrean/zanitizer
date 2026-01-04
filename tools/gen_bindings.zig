//! Build-time QuickJS binding generator
//! Generates type-safe wrappers using wrapper.zig types consistently
//!
//! Usage: zig run tools/gen_bindings.zig -- src/bindings_generated.zig

const std = @import("std");

const BindingSpec = struct {
    name: []const u8,
    zig_func_name: []const u8,
    kind: enum { static, method }, // static = on document, method = on prototype
    args: []const ArgType,
    return_type: ReturnType,
};

const ArgType = union(enum) {
    allocator, // std.mem.Allocator (retrieved from context, hidden from JS)

    // SOURCES
    this_element, // *HTMLElement from 'this'
    this_node, // *DomNode from 'this'
    element, // *HTMLElement from argv (passed as argument argv[i])
    node, // *DomNode from argv (passed as argument argv[i])
    document, // *HTMLDocument from global
    document_root, // *DomNode (root of document) from global

    // Primitives
    string, // []const u8
    int32, // i32
    uint32, // u32
    boolean, // bool
};

const ReturnType = union(enum) {
    void_type,
    element, // *HTMLElement
    optional_element, // ?*HTMLElement
    node, // *DomNode
    optional_node, // ?*DomNode
    document, // *HTMLDocument (No error)

    string, // []const u8 (allocated, will be freed with allocator from args)
    optional_string, // ?[]const u8
    int32,
    uint32,
    boolean,

    // Special cases
    error_string, // ![]const u8
    error_document, // !*HTMLDocument
};

// Define the bindings to generate
const bindings = [_]BindingSpec{
    // Document methods (Static on document object)
    .{
        .name = "createElement",
        .zig_func_name = "z.createElement",
        .kind = .static,
        .args = &.{ .document, .string },
        .return_type = .element, // Returns !*HTMLElement
    },
    .{
        .name = "documentRoot",
        .zig_func_name = "z.documentRoot",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_node,
    },
    .{
        .name = "bodyElement",
        .zig_func_name = "z.bodyElement",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_element,
    },
    .{
        .name = "ownerDocument",
        .zig_func_name = "z.ownerDocument",
        .kind = .static,
        .args = &.{.this_node},
        .return_type = .document,
    },
    .{
        .name = "createTextNode",
        .zig_func_name = "z.createTextNode",
        .kind = .static,
        .args = &.{ .document, .string },
        .return_type = .node, // Returns !*DomNode
    },
    .{
        .name = "getElementById",
        .zig_func_name = "z.getElementById",
        .kind = .static,
        .args = &.{ .document_root, .string },
        .return_type = .optional_element,
    },

    // Node/Element methods (Prototype methods)
    .{
        .name = "appendChild",
        .zig_func_name = "z.appendChild",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .void_type,
    },
    .{
        .name = "firstChild",
        .zig_func_name = "z.firstChild",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .optional_node,
    },
    .{
        .name = "parentNode",
        .zig_func_name = "z.parentNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .optional_node,
    },
    .{
        .name = "remove",
        .zig_func_name = "z.removeNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .void_type,
    },
    .{
        .name = "setAttribute",
        .zig_func_name = "z.setAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string, .string },
        .return_type = .void_type,
    },
    .{
        .name = "getAttribute",
        .zig_func_name = "z.getAttribute_zc",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .optional_string,
    },
    .{
        .name = "removeAttribute",
        .zig_func_name = "z.removeAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .void_type,
    },
    .{
        .name = "textContent",
        .zig_func_name = "z.textContent_zc",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .string,
    },
    .{
        .name = "setContentAsText",
        .zig_func_name = "z.setContentAsText",
        .kind = .method,
        .args = &.{ .this_node, .string },
        .return_type = .void_type,
    },
    .{
        .name = "setInnerHTML",
        .zig_func_name = "z.setInnerHTML",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .element, // Returns the element itself (or new root)
    },
    .{
        .name = "innerHTML",
        .zig_func_name = "z.innerHTML",
        .kind = .method,
        .args = &.{ .allocator, .this_element },
        .return_type = .error_string,
    },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <output_file>\n", .{args[0]});
        return;
    }

    const output_file_path = args[1];

    // Use Allocating writer to build output in memory
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const stdout = &aw.writer;

    try stdout.writeAll(
        \\// THIS FILE IS AUTO-GENERATED BY tools/gen_bindings.zig
        \\// DO NOT EDIT MANUALLY
        \\
        \\const std = @import("std");
        \\const z = @import("root.zig");
        \\const w = @import("wrapper.zig");
        \\const qjs = z.qjs;
        \\const DOMBridge = @import("dom_bridge.zig").DOMBridge;
        \\
        \\
    );

    for (bindings) |binding| {
        try genFunction(stdout, binding);
    }

    // Generate installers
    try stdout.writeAll("\n\n// Install static bindings (document-level factories)\n");
    try stdout.writeAll("pub fn installStaticBindings(ctx: ?*qjs.JSContext, doc_obj: qjs.JSValue) void {\n");
    for (bindings) |binding| {
        if (binding.kind == .static) {
            try stdout.print("    _ = qjs.JS_SetPropertyStr(ctx, doc_obj, \"{s}\", qjs.JS_NewCFunction(ctx, js_{s}, \"{s}\", {d}));\n", .{ binding.name, binding.name, binding.name, countJsArgs(binding.args) });
        }
    }
    try stdout.writeAll("}\n");

    try stdout.writeAll("\n// Install method bindings (shared via prototype)\n");
    try stdout.writeAll("pub fn installMethodBindings(ctx: ?*qjs.JSContext, proto: qjs.JSValue) void {\n");
    for (bindings) |binding| {
        if (binding.kind == .method) {
            try stdout.print("    _ = qjs.JS_SetPropertyStr(ctx, proto, \"{s}\", qjs.JS_NewCFunction(ctx, js_{s}, \"{s}\", {d}));\n", .{ binding.name, binding.name, binding.name, countJsArgs(binding.args) });
        }
    }
    try stdout.writeAll("}\n");

    // Write the accumulated output to file
    const file = try std.fs.cwd().createFile(output_file_path, .{});
    defer file.close();
    try file.writeAll(aw.writer.buffer[0..aw.writer.end]);
}

fn countJsArgs(args: []const ArgType) usize {
    var count: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .string, .int32, .uint32, .boolean, .element, .node => count += 1,
            else => {},
        }
    }
    return count;
}

fn genFunction(writer: *std.Io.Writer, func: BindingSpec) !void {
    try writer.print(
        \\
        \\/// Generated wrapper for {s}
        \\pub fn js_{s}(
        \\    ctx_ptr: ?*qjs.JSContext,
        \\    this_val: qjs.JSValue,
        \\    argc: c_int,
        \\    argv: [*c]qjs.JSValue,
        \\) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\
    , .{ func.zig_func_name, func.name });

    // 1. ARGUMENT CHECKS
    const js_arg_count = countJsArgs(func.args);
    if (js_arg_count > 0) {
        try writer.print("    if (argc < {d}) return w.EXCEPTION;\n", .{js_arg_count});
    }

    // 2. UNUSED VARS SUPPRESSION
    if (js_arg_count == 0) {
        try writer.writeAll("    _ = argc; _ = argv;\n");
    }
    var uses_this = false;
    var uses_ctx = false;
    for (func.args) |arg| {
        switch (arg) {
            .this_element, .this_node => uses_this = true,
            .string, .allocator, .document, .document_root, .element, .node => uses_ctx = true,
            else => {},
        }
    }
    if (!uses_this) {
        try writer.writeAll("    _ = this_val;\n");
    }
    // Suppress ctx usage check if nothing uses it
    // ctx is used if: args use it, or return type needs wrapping
    const return_needs_ctx = (func.return_type == .element or func.return_type == .node or
        func.return_type == .optional_element or func.return_type == .optional_node or
        func.return_type == .string or func.return_type == .error_string or func.return_type == .optional_string or
        func.return_type == .int32 or func.return_type == .uint32 or func.return_type == .boolean);
    if (!uses_ctx and !return_needs_ctx) {
        try writer.writeAll("    _ = ctx;\n");
    }

    // 3. EXTRACT ARGUMENTS
    var js_arg_idx: usize = 0;
    var allocator_idx: ?usize = null;

    for (func.args, 0..) |arg, i| {
        switch (arg) {
            .allocator => {
                // UPDATE: Use ctx.getAllocator() directly
                try writer.print("    const arg{d} = ctx.getAllocator();\n", .{i});
                allocator_idx = i;
            },
            .this_element => {
                try writer.print(
                    \\    const elem_ptr{d} = qjs.JS_GetOpaque(this_val, z.dom_class_id.*);
                    \\    if (elem_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.HTMLElement = @ptrCast(@alignCast(elem_ptr{d}));
                    \\
                , .{ i, i, i, i });
            },
            .this_node => {
                try writer.print(
                    \\    const node_ptr{d} = qjs.JS_GetOpaque(this_val, z.dom_class_id.*);
                    \\    if (node_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.DomNode = @ptrCast(@alignCast(node_ptr{d}));
                    \\
                , .{ i, i, i, i });
            },
            .document => {
                try writer.print(
                    \\    const global{d} = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global{d});
                    \\    const doc_obj{d} = ctx.getPropertyStr(global{d}, "document");
                    \\    defer ctx.freeValue(doc_obj{d});
                    \\    const native_doc{d} = ctx.getPropertyStr(doc_obj{d}, "_native_doc");
                    \\    defer ctx.freeValue(native_doc{d});
                    \\    const doc_ptr{d} = qjs.JS_GetOpaque(native_doc{d}, z.dom_class_id.*);
                    \\    if (doc_ptr{d} == null) return w.EXCEPTION;
                    \\    const arg{d}: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr{d}));
                    \\
                , .{ i, i, i, i, i, i, i, i, i, i, i, i, i });
            },
            .document_root => {
                try writer.print(
                    \\    const global{d} = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global{d});
                    \\    const doc_obj{d} = ctx.getPropertyStr(global{d}, "document");
                    \\    defer ctx.freeValue(doc_obj{d});
                    \\    const native_doc{d} = ctx.getPropertyStr(doc_obj{d}, "_native_doc");
                    \\    defer ctx.freeValue(native_doc{d});
                    \\    const doc_ptr{d} = qjs.JS_GetOpaque(native_doc{d}, z.dom_class_id.*);
                    \\    if (doc_ptr{d} == null) return w.EXCEPTION;
                    \\    const doc{d}: *z.HTMLDocument = @ptrCast(@alignCast(doc_ptr{d}));
                    \\    const root{d} = z.documentRoot(doc{d});
                    \\    if (root{d} == null) return w.EXCEPTION;
                    \\    const arg{d} = root{d}.?;
                    \\
                , .{ i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i });
            },
            .element => {
                try writer.print(
                    \\    const elem_arg_ptr{d} = qjs.JS_GetOpaque(argv[{d}], z.dom_class_id.*);
                    \\    if (elem_arg_ptr{d} == null) return ctx.throwTypeError("Argument {d} must be a DOM Element");
                    \\    const arg{d}: *z.HTMLElement = @ptrCast(@alignCast(elem_arg_ptr{d}));
                    \\
                , .{ i, js_arg_idx, i, js_arg_idx, i, i });
                js_arg_idx += 1;
            },
            .node => {
                try writer.print(
                    \\    const node_arg_ptr{d} = qjs.JS_GetOpaque(argv[{d}], z.dom_class_id.*);
                    \\    if (node_arg_ptr{d} == null) return ctx.throwTypeError("Argument {d} must be a DOM Node");
                    \\    const arg{d}: *z.DomNode = @ptrCast(@alignCast(node_arg_ptr{d}));
                    \\
                , .{ i, js_arg_idx, i, js_arg_idx, i, i });
                js_arg_idx += 1;
            },
            .string => {
                try writer.print(
                    \\    const arg{d} = ctx.toZString(argv[{d}]) catch return w.EXCEPTION;
                    \\    defer ctx.freeZString(arg{d});
                    \\
                , .{ i, js_arg_idx, i });
                js_arg_idx += 1;
            },
            .int32 => {
                try writer.print(
                    \\    var arg{d}: i32 = 0;
                    \\    if (qjs.JS_ToInt32(ctx_ptr, &arg{d}, argv[{d}]) != 0) return w.EXCEPTION;
                    \\
                , .{ i, i, js_arg_idx });
                js_arg_idx += 1;
            },
            .uint32 => {
                try writer.print(
                    \\    var arg{d}: u32 = 0;
                    \\    if (qjs.JS_ToUint32(ctx_ptr, &arg{d}, argv[{d}]) != 0) return w.EXCEPTION;
                    \\
                , .{ i, i, js_arg_idx });
                js_arg_idx += 1;
            },
            .boolean => {
                try writer.print("    const arg{d} = qjs.JS_ToBool(ctx_ptr, argv[{d}]) != 0;\n", .{ i, js_arg_idx });
                js_arg_idx += 1;
            },
        }
    }

    // 4. CALL NATIVE FUNCTION
    try writer.writeAll("    // Call native Zig function\n");

    // Special case: setAttribute returns a value we need to discard
    const is_set_attribute = std.mem.eql(u8, func.name, "setAttribute");

    if (func.return_type != .void_type) {
        try writer.writeAll("    const result = ");
    } else if (is_set_attribute) {
        try writer.writeAll("    _ = ");
    } else {
        try writer.writeAll("    ");
    }

    // Call
    try writer.print("{s}(", .{func.zig_func_name});
    for (func.args, 0..) |_, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("arg{d}", .{i});
    }
    try writer.writeAll(")");

    // Catch errors for non-void returns that are errors
    if (func.return_type == .element or func.return_type == .node or func.return_type == .error_string or func.return_type == .error_document) {
        try writer.writeAll(" catch return w.EXCEPTION");
    } else if (func.return_type == .void_type and !is_set_attribute) {
        // For void functions, only catch errors for specific functions we know return errors
        const is_remove_attr = std.mem.eql(u8, func.name, "removeAttribute");
        const is_set_content = std.mem.eql(u8, func.name, "setContentAsText");
        const is_set_inner = std.mem.eql(u8, func.name, "setInnerHTML");

        if (is_remove_attr or is_set_content or is_set_inner) {
            try writer.writeAll(" catch return w.EXCEPTION");
        }
    }
    try writer.writeAll(";\n\n");

    // 5. RETURN VALUE
    switch (func.return_type) {
        .void_type => try writer.writeAll("    return w.UNDEFINED;\n"),
        // UPDATE: Replace ctx_ptr with ctx in these calls
        .element => try writer.writeAll("    return DOMBridge.wrapElement(ctx, result) catch w.EXCEPTION;\n"),
        .node => try writer.writeAll("    return DOMBridge.wrapNode(ctx, result) catch w.EXCEPTION;\n"),

        .optional_element => try writer.writeAll("    if (result) |elem| { return DOMBridge.wrapElement(ctx, elem) catch w.EXCEPTION; } else { return w.NULL; }\n"),
        .optional_node => try writer.writeAll("    if (result) |node| { return DOMBridge.wrapNode(ctx, node) catch w.EXCEPTION; } else { return w.NULL; }\n"),

        .string, .error_string => {
            if (allocator_idx) |idx| {
                try writer.print("    defer arg{d}.free(result);\n    return ctx.newString(result);\n", .{idx});
            } else {
                try writer.writeAll("    return ctx.newString(result);\n");
            }
        },
        .optional_string => try writer.writeAll("    if (result) |str| { return ctx.newString(str); } else { return w.NULL; }\n"),
        .int32 => try writer.writeAll("    return ctx.newInt32(result);\n"),
        .uint32 => try writer.writeAll("    return ctx.newUint32(result);\n"),
        .boolean => try writer.writeAll("    return ctx.newBool(result);\n"),

        .document, .error_document => {
            // Document creation might still use manual objects if wrapDocument isn't in DOMBridge yet
            try writer.writeAll(
                \\    const doc_obj = qjs.JS_NewObjectClass(ctx_ptr, @intCast(z.dom_class_id.*));
                \\    _ = qjs.JS_SetOpaque(doc_obj, @ptrCast(result));
                \\    return doc_obj;
                \\
            );
        },
    }

    try writer.writeAll("}\n");
}
