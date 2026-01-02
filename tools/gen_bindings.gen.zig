//! Build-time QuickJS binding generator
//! Usage: zig run tools/gen_bindings.zig -- src/bindings_generated.zig

const std = @import("std");
// We can't import root.zig at comptime in a build tool, so we define types locally
// These must match your actual types
const HTMLDocument = opaque {};
const DomNode = opaque {};
const HTMLElement = opaque {};

const BindingSpec = struct {
    name: []const u8,
    // zig_func_name is the name in z.* namespace
    zig_func_name: []const u8,
    // Manually specify signature (no @TypeOf in build tool)
    args: []const ArgType,
    return_type: ReturnType,
};

const ArgType = union(enum) {
    allocator,
    this_element, // *HTMLElement from 'this'
    this_node, // *DomNode from 'this'
    document, // *HTMLDocument global singleton
    string, // []const u8
    int32, // i32
    uint32, // u32
    boolean, // bool
};

const ReturnType = union(enum) {
    void_type,
    element, // *HTMLElement
    node, // *DomNode
    string, // Assumes allocated with the function's allocator argument
    int32,
    uint32,
    boolean,

    // Error union variants
    error_void, // !void
    error_element, // !*HTMLElement
    error_node, // !*DomNode
    error_string, // ![]const u8
};

// ============================================================================
// API DEFINITION
// ============================================================================
const api_functions = [_]BindingSpec{
    // createElement(doc: *HTMLDocument, tag_name: []const u8) !*HTMLElement
    .{
        .name = "createElement",
        .zig_func_name = "createElement",
        .args = &.{ .document, .string },
        .return_type = .error_element,
    },
    // setAttribute(elem: *HTMLElement, name: []const u8, value: []const u8) !void
    .{
        .name = "setAttribute",
        .zig_func_name = "setAttribute",
        .args = &.{ .this_element, .string, .string },
        .return_type = .error_void,
    },
    // appendChild(parent: *DomNode, child: *DomNode) !void
    .{
        .name = "appendChild",
        .zig_func_name = "appendChild",
        .args = &.{ .this_node, .this_node },
        .return_type = .error_void,
    },
    // textContent(node: *DomNode, allocator: Allocator) ![]const u8
    .{
        .name = "textContent",
        .zig_func_name = "textContent",
        .args = &.{ .this_node, .allocator }, // Logic will detect 'allocator' to free return string
        .return_type = .error_string,
    },
    // getAttribute(elem: *HTMLElement, name: []const u8) ?[]const u8
    // Note: You might need to handle Optionals in ReturnType if getAttribute can return null
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("Usage: {s} <output_path>\n", .{args[0]});
        std.debug.print("Example: zig run tools/gen_bindings.zig -- src/bindings_generated.zig\n", .{});
        return error.InvalidArgs;
    }

    const out_path = args[1];

    std.debug.print("Generating bindings to: {s}\n", .{out_path});
    std.debug.print("Binding {d} functions...\n", .{api_functions.len});

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writeHeader(writer);
    for (api_functions) |spec| {
        try generateWrapper(writer, spec);
    }
    try writeFooter(writer);

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output.items });
}

fn writeHeader(writer: anytype) !void {
    try writer.writeAll(
        \\// AUTO-GENERATED FILE. DO NOT EDIT.
        \\const std = @import("std");
        \\const z = @import("root.zig");
        \\const w = @import("wrapper.zig");
        \\const qjs = z.qjs;
        \\const DOMBridge = @import("dom_bridge.zig").DOMBridge;
        \\
        \\
        \\// Helper to get allocator <-- !! why not onst getAllocator = @import("js_native_bridge.zig").getAllocator;??
        \\
        \\
        \\fn getAllocator(ctx: ?*qjs.JSContext) std.mem.Allocator {
        \\    const opaque_ptr = qjs.JS_GetContextOpaque(ctx);
        \\    const allocator_ptr: *std.mem.Allocator = @ptrCast(@alignCast(opaque_ptr));
        \\    return allocator_ptr.*;
        \\}
        \\
        \\
    );
}

fn writeFooter(writer: anytype) !void {
    try writer.writeAll(
        \\
        \\pub fn installAllBindings(ctx: ?*qjs.JSContext, target: qjs.JSValue) void {
    );
    for (api_functions) |spec| {
        // Calculate JS arg count (exclude internal args like allocator/this/doc)
        var js_argc: usize = 0;
        for (spec.args) |arg| {
            switch (arg) {
                .string, .int32, .uint32, .boolean => js_argc += 1,
                else => {},
            }
        }
        try writer.print(
            \\    _ = qjs.JS_SetPropertyStr(ctx, target, "{s}", qjs.JS_NewCFunction(ctx, js_{s}, "{s}", {d}));
            \\
        , .{ spec.name, spec.name, spec.name, js_argc });
    }
    try writer.writeAll("}\n");
}

fn countJSArgs(args: []const ArgType) u32 {
    var count: u32 = 0;
    for (args) |arg| {
        switch (arg) {
            .document, .this_element, .this_node => {},
            else => count += 1,
        }
    }
    return count;
}

fn generateWrapper(writer: anytype, spec: BindingSpec) !void {
    try writer.print(
        \\pub fn js_{s}(
        \\    ctx_ptr: ?*qjs.JSContext,
        \\    this_val: qjs.JSValue,
        \\    argc: c_int,
        \\    argv: [*c]qjs.JSValue,
        \\) callconv(.c) qjs.JSValue {{
        \\    const ctx = w.Context{{ .ptr = ctx_ptr }};
        \\
    , .{ spec.zig_func_name, spec.name });

    // Check argument count
    const expected_js_args = countJSArgs(spec.args);
    if (expected_js_args > 0) {
        try writer.print(
            \\    if (argc < {d}) return z.jsException; // Not enough arguments
            \\
        , .{expected_js_args});
    } else {
        try writer.writeAll(
            \\    _ = argc;
            \\    _ = argv;
            \\
        );
    }

    // 1. Argument Unpacking
    var js_arg_idx: usize = 0;
    var allocator_arg_name: ?[]const u8 = null;

    for (spec.args, 0..) |arg, i| {
        switch (arg) {
            .allocator => {
                // Keep track of the allocator variable name for freeing results later
                try writer.print("    const arg{d} = getAllocator(ctx_ptr);\n", .{i});
                // We assume there's only one allocator arg usually, but we need its name
                // for the return cleanup. Since we print "arg{d}", we can reconstruct it
                // or just hardcode the logic to look for the first allocator.
                // For simplicity in this generator, let's just remember we have one at index i.
                // But wait, we need the string name.
                // Let's just create an alias for clarity if we need to use it later.
                try writer.print("    const result_allocator = arg{d};\n", .{i});
                allocator_arg_name = "result_allocator";
            },
            .document => {
                // Fetch from global -> document -> _native_doc
                try writer.writeAll(
                    \\    const global = ctx.getGlobalObject();
                    \\    defer ctx.freeValue(global);
                    \\    const doc_obj = ctx.getPropertyStr(global, "document");
                    \\    defer ctx.freeValue(doc_obj);
                    \\    const nat_doc = ctx.getPropertyStr(doc_obj, "_native_doc");
                    \\    defer ctx.freeValue(nat_doc);
                    \\    // Uses z.dom_class_id (from root.zig) to avoid circular dep
                    \\    const ptr_doc = qjs.JS_GetOpaque(nat_doc, z.dom_class_id);
                    \\    if (ptr_doc == null) return z.jsException();
                );
                try writer.print("    const arg{d}: *z.HTMLDocument = @ptrCast(@alignCast(ptr_doc));\n", .{i});
            },
            .this_element, .this_node => {
                try writer.writeAll(
                    \\    const nat_el = ctx.getPropertyStr(this_val, "_native_element");
                    \\    defer ctx.freeValue(nat_el);
                    \\    const ptr_el = qjs.JS_GetOpaque(nat_el, z.dom_class_id);
                    \\    if (ptr_el == null) return z.jsException();
                );
                const cast_type = if (arg == .this_element) "*z.HTMLElement" else "*z.DomNode";
                try writer.print("    const arg{d}: {s} = @ptrCast(@alignCast(ptr_el));\n", .{ i, cast_type });
            },
            .string => {
                try writer.print(
                    \\    if (argc <= {d}) return ctx.throwTypeError("Missing argument {d}");
                    \\    const arg{d} = ctx.toZString(argv[{d}]) catch return z.jsException();
                    \\    defer ctx.freeZString(arg{d});
                    \\
                , .{ js_arg_idx, js_arg_idx, i, js_arg_idx, i });
                js_arg_idx += 1;
            },
            // ... int/bool logic identical to your draft ...
            else => {},
        }
    }

    // 2. Call Logic
    try writer.writeAll("\n    const result = z." ++ spec.zig_func_name ++ "(");
    for (spec.args, 0..) |_, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("arg{d}", .{i});
    }
    try writer.writeAll(")");

    // 3. Error Handling
    const is_error = switch (spec.return_type) {
        .error_void, .error_element, .error_node, .error_string => true,
        else => false,
    };
    if (is_error) {
        try writer.writeAll(" catch return z.jsException();\n");
    } else {
        try writer.writeAll(";\n");
    }

    // 4. Return Marshalling
    switch (spec.return_type) {
        .void_type, .error_void => try writer.writeAll("    return z.jsUndefined();\n"),
        .element, .error_element => try writer.writeAll("    return DOMBridge.wrapElement(ctx_ptr, result) catch z.jsException();\n"),
        .string, .error_string => {
            // FIX: Use the Zig allocator (result_allocator) to free the Zig result string!
            if (allocator_arg_name) |alloc_name| {
                try writer.print("    defer {s}.free(result);\n", .{alloc_name});
                try writer.writeAll("    return ctx.newString(result);\n");
            } else {
                // If no allocator was passed, we can't safely free it unless we know the API returns
                // static strings or uses a global allocator. Warn or error here.
                try writer.writeAll("    // WARNING: Returning string without allocator arg to free it!\n");
                try writer.writeAll("    return ctx.newString(result);\n");
            }
        },
        else => try writer.writeAll("    return z.jsUndefined(); // TODO: impl type\n"),
    }

    try writer.writeAll("}\n\n");
}
