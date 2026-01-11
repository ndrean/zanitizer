// const std = @import("std");
// const z = @import("root.zig");
// const curl = @import("curl");

// pub const FetchContext = struct {
//     // Input
//     URL: []const u8,
//     // Output
//     status: i64 = 0,
//     body: ?[]u8 = null, // Owned by heap
//     err_msg: ?[]u8 = null,

//     pub fn deinit(self: *FetchContext, allocator: std.mem.Allocator) void {
//         allocator.free(self.url);
//         if (self.body) |b| allocator.free(b);
//         if (self.err_msg) |e| allocator.free(e);
//         allocator.destroy(self);
//     }

//     fn fail(self: *FetchContext, allocator: std.mem.Allocator, err: anytype) void {
//         self.err_msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch null;
//         return;
//     }
// };

// // This runs on the WORKER THREAD - can't return errors
// fn workerFetch(allocator: std.mem.Allocator, ctx: *FetchContext) void {

//     // 1. Setup Curl
//     const ca_bundle = curl.allocCABundle(allocator) catch |err| {
//         ctx.fail(allocator, @errorName(err));
//         return;
//     };
//     defer ca_bundle.deinit();

//     const easy = curl.Easy.init(.{
//         .ca_bundle = ca_bundle,
//     }) catch |err| {
//         ctx.fail(allocator, @errorName(err));
//         return;
//     };
//     defer easy.deinit();

//     var writer = std.Io.Writer.Allocating.init(allocator);
//     defer writer.deinit();

//     // 2. Create null-terminated URL
//     const zURL = allocator.dupeZ(u8, ctx.URL) catch |err| {
//         ctx.fail(allocator, @errorName(err));
//         return;
//     };
//     defer allocator.free(zURL);

//     const response = easy.fetch(
//         zURL,
//         .{ .writer = &writer },
//     ) catch |err| {
//         ctx.fail(allocator, @errorName(err));
//         return;
//     };

//     ctx.status = response.status_code;
//     ctx.body = writer.toOwnedSlice() catch |err| {
//         ctx.fail(allocator, @errorName(err));
//         return;
//     };
// }

// // The result structure we will pass back to JS
// pub const FetchResult = struct {
//     status: i32, // Matches curl library's status_code type
//     body: []u8,
// };

// pub const FetchTask = struct {
//     allocator: std.mem.Allocator,
//     url: []const u8,

//     // Output fields (filled by worker)
//     result: ?FetchResult = null,
//     err_msg: ?[]u8 = null,

//     pub fn init(allocator: std.mem.Allocator, url: []const u8) !*FetchTask {
//         z.print("[Fetch] Init", .{});
//         // heap allocate
//         const self = try allocator.create(FetchTask);
//         self.* = .{
//             .allocator = allocator,
//             .url = try allocator.dupe(u8, url),
//         };
//         return self;
//     }

//     pub fn deinit(self: *FetchTask) void {
//         self.allocator.free(self.url);
//         if (self.result) |res| {
//             self.allocator.free(res.body);
//         }
//         if (self.err_msg) |msg| {
//             self.allocator.free(msg);
//         }
//         self.allocator.destroy(self);
//     }

//     // This runs on the WORKER THREAD
//     pub fn execute(self: *FetchTask) void {
//         // 1. Setup Curl
//         const ca_bundle = curl.allocCABundle(self.allocator) catch |err| {
//             self.fail(@errorName(err));
//             return;
//         };
//         defer ca_bundle.deinit();

//         const easy = curl.Easy.init(.{
//             .ca_bundle = ca_bundle,
//         }) catch |err| {
//             self.fail(@errorName(err));
//             return;
//         };
//         defer easy.deinit();

//         // 2. Create null-terminated URL
//         const url_z = self.allocator.dupeZ(u8, self.url) catch |err| {
//             self.fail(@errorName(err));
//             return;
//         };
//         defer self.allocator.free(url_z);

//         // 3. Test with fixed buffer first
//         var buffer: [10 * 1024 * 1024]u8 = undefined; // 10MB buffer
//         var writer = std.Io.Writer.fixed(&buffer);

//         const resp = easy.fetch(url_z, .{ .writer = &writer }) catch |err| {
//             self.fail(@errorName(err));
//             return;
//         };

//         // Copy the buffered data to heap
//         const body_data = writer.buffered();
//         const body_copy = self.allocator.dupe(u8, body_data) catch {
//             self.fail("OOM");
//             return;
//         };

//         self.result = .{
//             .status = resp.status_code,
//             .body = body_copy,
//         };
//     }

//     fn fail(self: *FetchTask, msg: []const u8) void {
//         self.err_msg = self.allocator.dupe(u8, msg) catch null;
//     }
// };
