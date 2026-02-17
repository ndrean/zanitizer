//! Fast DOM traverse utilities using `simple_Walk`  with Callbacks
//! GENERIC DOM SEARCH PATTERN
//!
//! The search functions below use a generic pattern from walker.zig that allows
//! efficient DOM traversal with custom matching logic. Here's how it works:
//!
//! **Pattern Structure:**
//! 1. Define a Context struct with mandatory fields:
//!    - `found_element: ?*z.HTMLElement` (for single element search)
//!    - `matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int` (callback)
//!    - Custom fields for search criteria (target_id, target_class, etc.)
//!
//! 2. Implement the matcher function that:
//!    - Returns `z._CONTINUE` to keep searching
//!    - Returns `z._STOP` when match found (sets `found_element`)
//!
//! 3. Call `z.genSearchElement(ContextType, root_node, &context_instance)`
//!
//! **Example Pattern:**
//! ```zig
//! const MyContext = struct {
//!     target: []const u8,
//!     found_element: ?*z.HTMLElement = null,
//!     matcher: *const fn (*z.DomNode, *@This()) callconv(.c) c_int,
//!
//!     fn implement(node: *z.DomNode, ctx: *@This()) callconv(.c) c_int {
//!         // Your matching logic here
//!         if (matches_criteria(node, ctx.target)) {
//!             ctx.found_element = z.nodeToElement(node);
//!             return z._STOP;
//!         }
//!         return z._CONTINUE;
//!     }
//! };
//! ```
//!
//! This pattern provides:
//! - Type-safe context passing
//! - Efficient single-pass DOM traversal
//! - Early termination on first match
//! - Zero heap allocation for search logic
//!
//! See walker.zig for genSearchElements() (multiple results) and genProcessAll() (side effects)

//======================================================================
// DOM SEARCH USING WALKER CALLBACKS
//=======================================================================

const std = @import("std");
const z = @import("../root.zig");
const Err = z.Err;
const print = std.debug.print;

const testing = std.testing;

// Fast DOM traversal for optimized search
extern "c" fn lxb_dom_node_simple_walk(
    root: *z.DomNode,
    walker_cb: *const fn (*z.DomNode, ?*anyopaque) callconv(.c) c_int,
    ctx: ?*anyopaque,
) void;

/// [walker] Traverse the DOM (safe Zig re-implementation with cycle guard)
/// Mirrors lxb_dom_node_simple_walk but adds a max-iteration limit to prevent
/// infinite loops when DOM tree pointers are corrupted by JS-driven mutations.
pub fn simpleWalk(
    root: *z.DomNode,
    callback: *const fn (*z.DomNode, ?*anyopaque) callconv(.c) c_int,
    ctx: ?*anyopaque,
) void {
    const max_iterations: usize = 500_000;
    var iterations: usize = 0;
    var node: ?*z.DomNode = z.firstChild(root);

    while (node) |n| {
        iterations += 1;
        if (iterations > max_iterations) {
            std.debug.print("[walker] SAFETY LIMIT: {d} iterations on simpleWalk, aborting (DOM too large or corrupted)\n", .{max_iterations});
            return;
        }

        const action = callback(n, ctx);
        if (action == z._STOP) return;

        // LEXBOR_ACTION_NEXT (2) = skip children. Our callbacks only return
        // _CONTINUE (0) or _STOP (1), so check action != 2 for completeness.
        if (z.firstChild(n) != null and action != 2) {
            node = z.firstChild(n);
        } else {
            // Go up until we find a node with a next sibling (or hit root)
            var current: *z.DomNode = n;
            while (current != root and z.nextSibling(current) == null) {
                current = z.parentNode(current) orelse return; // null parent = bail
            }
            if (current == root) return;
            node = z.nextSibling(current);
        }
    }
}

/// [walker] Count total nodes in a subtree (for diagnostics)
pub fn countNodes(root: *z.DomNode) usize {
    var count: usize = 0;
    const counter = struct {
        fn cb(_: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
            const c: *usize = @ptrCast(@alignCast(ctx.?));
            c.* += 1;
            return z._CONTINUE;
        }
    }.cb;
    simpleWalk(root, counter, @ptrCast(&count));
    return count;
}

/// Helper to convert "aligned" `anyopaque` to the target pointer type `T`
/// ```
/// const my_ctx: *IdCtx = castCtx(MyCtx, ctx: ?*anyopaque);
/// ```
pub fn castContext(comptime T: type, ctx: ?*anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ctx.?)));
}

pub fn toAnyOpaque(comptime T: type, ptr: *T) ?*anyopaque {
    return @as(?*anyopaque, @ptrCast(ptr));
}

/// [walker] Generic walker for _single matching element_ (**stops on first match**)
///
///
/// The `matcher` signature is `fn (*z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int`.
///
/// It returns `z._CONTINUE = 0` to keep walking, or `z._STOP = 1` to stop.
///
/// 1. Define a context struct with at least these two mandatory field names:
/// - `matcher` with the signature above,
/// - `found_element: z.HTMLElement`.
/// -  you can add other fields such as `target_id`, `target_class`, etc.
///
/// 2. Instantiate a mutable instance of that struct and pass its address to `genSearchElement`.
/// ### Example:
/// ````
/// const IdContext = struct {
///    found_element: *z.HTMLElement = null,
///    matcher: *const fn (*z.DomNode, ctx: *@This()) c_int,
///    target_id: []const u8, // your field
///    fn implementation(node: *z.DomNode, ctx: *@This()) c_int {...} // your implementation
/// };
/// var id_context_instance = IdContext{
///   .target_id = id_argument, // your input
///   .matcher = IdContext.implementation,
/// };
/// genSearchElement(IdContext, root_node, &id_context_instance);
/// ```
pub fn genSearchElement(comptime ContextType: type, root_node: *z.DomNode, context: *ContextType) ?*z.HTMLElement {
    const matcher = struct {
        fn cb(node: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
            if (!z.isTypeElement(node)) return z._CONTINUE;
            const typed_ctx: *ContextType = @ptrCast(@alignCast(ctx.?));

            return typed_ctx.matcher(node, typed_ctx);
        }
    }.cb;

    simpleWalk(
        root_node,
        matcher,
        @as(?*anyopaque, @ptrCast(context)),
    );
    return context.found_element;
}

/// [walker] Generic walker to find _multiple matching elements_ (**continues until end**)
///
/// The context holds the allocator and an ArrayList to collect results.
///
/// The mandatory field names are `matcher`, `results`. cf `genSearchElement` for details.
///
/// You can use this function to capture elements.
///
/// If you just want to run side-effects, use `genProcessAll`, for removal for example.
///
/// Notice that any DOM modification should be done in a post-processing step.
pub fn genSearchElements(comptime ContextType: type, root_node: *z.DomNode, context: *ContextType) ![]const *z.HTMLElement {
    const matcher = struct {
        fn cb(node: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
            if (!z.isTypeElement(node)) return z._CONTINUE;

            var typed_ctx = castContext(ContextType, ctx);
            return typed_ctx.matcher(node, typed_ctx);
        }
    }.cb;
    //
    simpleWalk(
        root_node,
        matcher,
        toAnyOpaque(ContextType, context),
    );
    return context.results.toOwnedSlice(context.allocator);
}

/// [walker] Generic runtime walker to "process all elements" with a given `processor` function on the nodes.
///
/// Use this function to run side-effects, like removal. Notice that any DOM modification should be done in a post-processing step.
///
/// The `processor` signature is `fn (*z.DomNode, ctx: ?*anyopaque) c_int`. It returns `z._CONTINUE = 0` to keep walking, or `z._STOP = 1` to stop.
///
/// 1. Define a context struct with the mandatory field `processor` and any extra fields you need.
/// with the same signature.
/// 2. Take a mutable instance of that struct and pass it to `genProcessAll`.
/// ### Example:
/// ````
/// const MyContext = struct {
///    allocator: std.mem.Allocator,
///    processor: *const fn (*z.DomNode, ctx: *@This()) c_int,
///    extra_field: u32, // any extra fields you need
///    fn myProcessor(node: *z.DomNode, ctx: *@This()) c_int {...}
/// };
/// var my_context_instance = MyContext{
///   .allocator = allocator,
///   .processor = &MyContext.myProcessor,
///   .extra_field = 42,
///   .processor = &MyContext.myProcessor,
/// };
/// GenProcessAll(MyContext, root_node, &my_context_instance);
/// ```
///
/// `genProcessAll(MyContext, root_node, &my_context_instance)`.
pub fn genProcessAll(comptime ContextType: type, root_node: *z.DomNode, context: *ContextType) void {
    const processor = struct {
        fn cb(node: *z.DomNode, ctx: ?*anyopaque) callconv(.c) c_int {
            if (!z.isTypeElement(node)) return z._CONTINUE;
            var typed_ctx = castContext(ContextType, ctx);
            return typed_ctx.processor(node, typed_ctx);
        }
    }.cb;

    simpleWalk(
        root_node,
        processor,
        toAnyOpaque(ContextType, context),
    );
}
