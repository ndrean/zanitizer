const std = @import("std");

pub const Node = struct {
    nodeName: []const u8,

    pub fn constructor(name: []const u8) Node {
        return .{ .nodeName = name };
    }

    pub fn _toString(self: Node) []const u8 {
        return self.nodeName;
    }

    pub fn get_nodeType(self: Node) u32 {
        _ = self;
        return 1;
    }

    // [FIX] Node expects to own 'nodeName', so it frees it.
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.nodeName);
    }
};

pub const HTMLElement = struct {
    pub const prototype = *Node;

    base: Node,
    tagName: []const u8,

    pub fn constructor(tagName: []const u8) HTMLElement {
        return .{
            .base = Node.constructor(tagName),
            .tagName = tagName,
        };
    }

    pub fn _click(self: *HTMLElement) void {
        std.debug.print("Clicked on {s}!\n", .{self.tagName});
    }

    pub fn deinit(self: *HTMLElement, allocator: std.mem.Allocator) void {
        allocator.free(self.tagName);
        // Do NOT free base.nodeName because it points to tagName!
        // self.base.deinit(allocator);
    }
};

pub const Document = struct {
    pub const prototype = *Node;

    base: Node,
    url: []const u8,

    pub fn constructor(url: []const u8) Document {
        return .{
            // [FIX] Use 'url' instead of static "#document" to avoid freeing static memory.
            // Since 'url' is duped by reflection, it is safe to free.
            .base = Node.constructor(url),
            .url = url,
        };
    }

    pub fn get_URL(self: Document) []const u8 {
        return self.url;
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        // Do NOT free base because it points to url!
    }
};
// const std = @import("std");

// pub const Node = struct {
//     nodeName: []const u8,

//     pub fn constructor(name: []const u8) Node {
//         return .{ .nodeName = name };
//     }

//     // Renamed to remove underscore for JS (Reflection handles binding)
//     // But wait, Reflection logic strips '_', so '_toString' -> 'toString' is correct.
//     pub fn _toString(self: Node) []const u8 {
//         return self.nodeName;
//     }

//     pub fn get_nodeType(self: Node) u32 {
//         _ = self;
//         return 1;
//     }

//     pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
//         allocator.free(self.nodeName);
//     }
// };

// pub const HTMLElement = struct {
//     pub const prototype = *Node;

//     base: Node,
//     tagName: []const u8,

//     pub fn constructor(tagName: []const u8) HTMLElement {
//         return .{
//             // Both structs point to the SAME slice memory
//             .base = Node.constructor(tagName),
//             .tagName = tagName,
//         };
//     }

//     pub fn _click(self: *HTMLElement) void {
//         std.debug.print("Clicked on {s}!\n", .{self.tagName});
//     }

//     pub fn deinit(self: *HTMLElement, allocator: std.mem.Allocator) void {
//         // 1. Free the string (owned by us)
//         allocator.free(self.tagName);

//         // 2. CRITICAL: Do NOT call self.base.deinit(allocator)
//         // because self.base.nodeName points to the SAME memory we just freed.
//         // self.base.deinit(allocator); <--- REMOVE THIS
//     }
// };

// pub const Document = struct {
//     pub const prototype = *Node;

//     base: Node,
//     url: []const u8,

//     pub fn constructor(url: []const u8) Document {
//         return .{
//             // Here we have a literal "#document", which is not malloc'd.
//             // BUT reflection 'dupes' arguments, so 'url' is malloc'd.
//             // However, "#document" is passed internally.
//             // We need to be careful. For this mock, let's just use 'url' for both to be safe/lazy
//             // or manually duplicate "#document" if we were serious.
//             // Simplified:
//             .base = Node.constructor("document"),
//             .url = url,
//         };
//     }

//     pub fn get_URL(self: Document) []const u8 {
//         return self.url;
//     }

//     pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
//         allocator.free(self.url);
//         // Base was init with literal "document" (const), so don't free base!
//     }
// };
