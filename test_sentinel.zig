const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test 1: readFileAlloc
    const content1 = try std.fs.cwd().readFileAlloc(allocator, "js/worker_task.js", 1024);
    defer allocator.free(content1);
    std.debug.print("readFileAlloc type: {s}\n", .{@typeName(@TypeOf(content1))});
    std.debug.print("Is null-terminated: {}\n", .{content1.len < content1.ptr[0..content1.len :0].len});
    
    // Test 2: readFileAllocOptions with sentinel 0
    const content2 = try std.fs.cwd().readFileAllocOptions(
        allocator, 
        "js/worker_task.js", 
        1024,
        null,
        std.mem.Alignment.fromByteUnits(1),
        0  // sentinel value
    );
    defer allocator.free(content2);
    std.debug.print("\nreadFileAllocOptions type: {s}\n", .{@typeName(@TypeOf(content2))});
}
