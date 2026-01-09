const std = @import("std");

/// Generic CSV Parser using Compile-Time Reflection
/// Input: Raw CSV string (entire file)
/// Output: ArrayList of Structs
pub fn parseCSVtoJSON(comptime T: type, allocator: std.mem.Allocator, csv_content: []const u8) ![]T {
    var list: std.ArrayList(T) = .{};
    errdefer list.deinit(allocator);

    // Iterate over lines
    var lines = std.mem.splitScalar(u8, csv_content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r \t");
        if (trimmed.len == 0) continue; // Skip empty lines

        var value: T = undefined;
        var cols = std.mem.splitScalar(u8, trimmed, ',');

        // ⚡️ Compile-Time Magic: Iterate over struct fields
        inline for (std.meta.fields(T)) |field| {
            const raw_val = cols.next() orelse "";

            // Handle types
            switch (field.type) {
                i32 => @field(value, field.name) = std.fmt.parseInt(i32, raw_val, 10) catch 0,
                f64 => @field(value, field.name) = std.fmt.parseFloat(f64, raw_val) catch 0.0,
                []const u8 => {
                    // Critical: We must duplicate string data because 'raw_val' points
                    // to 'csv_content' which might be freed later if not careful.
                    // For this async worker, we usually own the payload, so pointing to it is fine
                    // IF the payload survives. To be safe/clean, we dupe.
                    @field(value, field.name) = try allocator.dupe(u8, raw_val);
                },
                bool => @field(value, field.name) = std.mem.eql(u8, raw_val, "true"),
                else => {},
            }
        }
        try list.append(allocator, value);
    }

    return list.toOwnedSlice(allocator);
}

pub const ProductRow = std.meta.Tuple(&.{ i32, []const u8, f64 });

pub fn parseCSVToTuples(allocator: std.mem.Allocator, csv_text: []u8) ![]ProductRow {
    // We use an ArrayList of Tuples
    var list: std.ArrayList(ProductRow) = .{};
    errdefer list.deinit(allocator);

    var lines = std.mem.splitScalar(u8, csv_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r \t");
        if (trimmed.len == 0) continue;

        var cols = std.mem.splitScalar(u8, trimmed, ',');

        // Parse fields
        const id_str = cols.next() orelse "0";
        const name_raw = cols.next() orelse "";
        const price_str = cols.next() orelse "0";

        const id = std.fmt.parseInt(i32, id_str, 10) catch 0;
        // MUST duplicate string because 'csv_text' might be freed/reused
        const name = try allocator.dupe(u8, name_raw);
        const price = std.fmt.parseFloat(f64, price_str) catch 0.0;

        // Append as a Tuple (anonymous struct literal)
        try list.append(allocator, .{ id, name, price });
    }

    return list.toOwnedSlice(allocator);
}
