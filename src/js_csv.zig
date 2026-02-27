const std = @import("std");
const z = @import("root.zig");
const zqjs = z.wrapper;
const qjs = z.qjs;

// ---------------------------------------------------------------------------
// JS Binding: zxp.csv.parse(csv_string) -> Array of Objects
// ---------------------------------------------------------------------------
pub fn js_native_parseCSV(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);
    const alloc = rc.allocator;

    if (argc < 1 or !ctx.isString(argv[0])) {
        return qjs.JS_ThrowTypeError(ctx.ptr, "csv.parse requires a CSV string");
    }

    const csv_str = ctx.toZString(argv[0]) catch return zqjs.EXCEPTION;
    defer ctx.freeZString(csv_str);

    // Create the return Array
    const js_array = ctx.newArray();
    if (ctx.isException(js_array)) return zqjs.EXCEPTION;

    var lines = std.mem.splitScalar(u8, csv_str, '\n');

    // Headers, first line
    const header_line = lines.next() orelse {
        return js_array; // empty CSV
    };

    var header_list: std.ArrayList([]const u8) = .empty;
    defer header_list.deinit(alloc);

    var header_split = std.mem.splitScalar(u8, std.mem.trim(u8, header_line, "\r "), ',');
    while (header_split.next()) |h| {
        header_list.append(alloc, std.mem.trim(u8, h, " \"")) catch continue;
    }

    if (header_list.items.len == 0) return js_array;

    // Data Rows
    var row_index: u32 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r \t");
        if (trimmed.len == 0) continue;

        const row_obj = ctx.newObject();
        var cols = std.mem.splitScalar(u8, trimmed, ',');
        var col_idx: usize = 0;

        while (cols.next()) |col_val| : (col_idx += 1) {
            if (col_idx >= header_list.items.len) break;

            const clean_val = std.mem.trim(u8, col_val, " \"");
            const header_name = header_list.items[col_idx];

            // Allocate a null-terminated string for the property key
            const key_z = alloc.dupeZ(u8, header_name) catch continue;
            defer alloc.free(key_z);

            const js_val = ctx.newString(clean_val);
            _ = ctx.setPropertyStr(row_obj, key_z, js_val) catch {};
        }

        // Append object to the array
        _ = ctx.setPropertyUint32(js_array, row_index, row_obj) catch {};
        row_index += 1;
    }

    return js_array;
}

// ---------------------------------------------------------------------------
// JS Binding: zxp.csv.stringify(array_of_objects) -> String
// ---------------------------------------------------------------------------
pub fn js_native_stringifyCSV(
    ctx_ptr: ?*qjs.JSContext,
    _: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue {
    const ctx = zqjs.Context.from(ctx_ptr);
    const rc = z.RuntimeContext.get(ctx);
    const alloc = rc.allocator;

    if (argc < 1 or !ctx.isArray(argv[0])) {
        return ctx.throwTypeError("csv.stringify requires an Array of Objects");
    }

    const js_array = argv[0];
    const length_val = ctx.getPropertyStr(js_array, "length");
    defer ctx.freeValue(length_val);

    const length: u32 = ctx.toUint32(length_val) catch return ctx.newString("");
    if (length == 0) return ctx.newString("");

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(alloc);

    // 1. Get enumerable string keys from the first object
    const first_row = ctx.getPropertyUint32(js_array, 0);
    defer ctx.freeValue(first_row);

    const props = ctx.getOwnPropertyNames(first_row, .{ .enum_only = true }) catch return zqjs.EXCEPTION;
    defer ctx.freePropertyEnum(props);

    // Collect null-terminated header strings (owned, reused for each row lookup)
    var headers: std.ArrayList([:0]u8) = .empty;
    defer {
        for (headers.items) |h| alloc.free(h);
        headers.deinit(alloc);
    }

    // Write header row
    var is_first_col = true;
    for (props) |pe| {
        const key_cstr = ctx.atomToCString(pe.atom) catch continue;
        defer ctx.freeCString(key_cstr);

        const key_dup = alloc.dupeZ(u8, std.mem.span(key_cstr)) catch continue;
        headers.append(alloc, key_dup) catch {
            alloc.free(key_dup);
            continue;
        };

        if (!is_first_col) out_buf.append(alloc, ',') catch {};
        out_buf.writer(alloc).print("\"{s}\"", .{key_cstr}) catch {};
        is_first_col = false;
    }
    out_buf.append(alloc, '\n') catch {};

    // 2. Iterate array and write values
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const row = ctx.getPropertyUint32(js_array, i);
        defer ctx.freeValue(row);

        is_first_col = true;
        for (headers.items) |header| {
            if (!is_first_col) out_buf.append(alloc, ',') catch {};

            const val = ctx.getPropertyStr(row, header);
            defer ctx.freeValue(val);

            if (!ctx.isUndefined(val) and !ctx.isNull(val)) {
                const val_str = ctx.toZString(val) catch {
                    is_first_col = false;
                    continue;
                };
                defer ctx.freeZString(val_str);

                // Basic escaping: wrap in quotes if contains comma, newline or quote
                if (std.mem.indexOfAny(u8, val_str, ",\n\"") != null) {
                    out_buf.writer(alloc).print("\"{s}\"", .{val_str}) catch {};
                } else {
                    out_buf.appendSlice(alloc, val_str) catch {};
                }
            }
            is_first_col = false;
        }
        out_buf.append(alloc, '\n') catch {};
    }

    return ctx.newString(out_buf.items);
}
