//! Pre-compiled JavaScript bytecode for fast module loading
//!
//! This module provides pre-compiled bytecode for commonly used libraries.
//! Benefits:
//! - No parsing at runtime (faster cold start)
//! - Smaller memory footprint
//! - Validated at compile time
//!
//! To generate bytecode:
//!   1. Download the ESM source: curl -o preact.mjs "https://cdn.jsdelivr.net/npm/preact@10.19.3/+esm"
//!   2. Compile to bytecode: qjsc -c -m -o preact.bc preact.mjs
//!   3. Place in vendor/bytecode/
//!
//! Or use: zig build gen-bytecode

const std = @import("std");
const z = @import("root.zig");
const qjs = z.qjs;
const w = z.wrapper;

/// Registry of pre-compiled bytecode modules
pub const BytecodeRegistry = struct {
    allocator: std.mem.Allocator,

    /// Map from module specifier to bytecode blob
    const Entry = struct {
        bytecode: []const u8,
        /// Original source URL (for debugging)
        source_url: []const u8,
    };

    /// Check if a module has pre-compiled bytecode available
    pub fn get(specifier: []const u8) ?[]const u8 {
        // Static mapping of module names to embedded bytecode
        // These are embedded at compile time using @embedFile
        return bytecode_map.get(specifier);
    }

    /// Load a bytecode module into the context
    pub fn loadModule(ctx: w.Context, _: []const u8, bytecode: []const u8) !w.Value {
        // Read the bytecode object
        const obj = ctx.readObject(bytecode, .{ .bytecode = true });
        if (obj.isException()) {
            return error.BytecodeLoadFailed;
        }

        // Evaluate the module (this instantiates it)
        const result = qjs.JS_EvalFunction(ctx.ptr, obj);
        if (w.Value.isException(result)) {
            return error.BytecodeEvalFailed;
        }

        return result;
    }
};

/// Static map of module specifiers to bytecode
/// Add entries here as bytecode files are generated
const bytecode_map = std.StaticStringMap([]const u8).initComptime(.{
    // Uncomment when bytecode files exist:
    // .{ "preact", @embedFile("../vendor/bytecode/preact.bc") },
    // .{ "preact/hooks", @embedFile("../vendor/bytecode/preact-hooks.bc") },
    // .{ "htm/preact/standalone", @embedFile("../vendor/bytecode/htm-preact-standalone.bc") },
});

/// Check if bytecode is available for a specifier
pub fn hasBytecode(specifier: []const u8) bool {
    return bytecode_map.has(specifier);
}

/// Get bytecode for a specifier (returns null if not available)
pub fn getBytecode(specifier: []const u8) ?[]const u8 {
    return bytecode_map.get(specifier);
}

// =============================================================================
// Build-time bytecode generation helpers
// =============================================================================

/// Generate bytecode from JavaScript source
/// This is called from build.zig to create .bc files
pub fn compileToBytecode(
    ctx: w.Context,
    source: []const u8,
    module_name: []const u8,
) ![]u8 {
    // Compile the module
    const flags = qjs.JS_EVAL_TYPE_MODULE | qjs.JS_EVAL_FLAG_COMPILE_ONLY;
    const result = qjs.JS_Eval(
        ctx.ptr,
        source.ptr,
        source.len,
        module_name.ptr,
        flags,
    );

    if (w.Value.isException(result)) {
        return error.CompilationFailed;
    }
    defer ctx.freeValue(result);

    // Serialize to bytecode
    return ctx.writeObject(result, .{
        .bytecode = true,
        .strip_source = true, // Remove source for smaller size
        .strip_debug = false, // Keep debug info for stack traces
    });
}

// =============================================================================
// Tests
// =============================================================================

test "bytecode registry lookup" {
    // Test that the registry returns null for unknown modules
    const result = getBytecode("unknown-module");
    try std.testing.expect(result == null);

    // Test hasBytecode
    try std.testing.expect(!hasBytecode("unknown-module"));
}
