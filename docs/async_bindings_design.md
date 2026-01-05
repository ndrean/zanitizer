# Async Bindings Design for gen_bindings.zig

## Problem
The current `gen_bindings.zig` only handles synchronous operations. Async operations like `js_fetch` and `js_simulateWork` contain lots of boilerplate:
- Getting EventLoop from context
- Parsing arguments
- Creating Promise with `JS_NewPromiseCapability`
- Creating worker task struct
- Spawning worker with error handling

This boilerplate is identical across all async bindings and should be auto-generated.

## Solution: Extend gen_bindings.zig to use async_bridge.zig

### 1. Add `.promise` to ReturnType

```zig
const ReturnType = union(enum) {
    // ... existing types ...

    // Async operation - returns a Promise
    promise: struct {
        payload_type: []const u8,  // e.g., "FetchPayload"
        worker_func: []const u8,   // e.g., "Worker.workerFetchHTTP"
    },
};
```

### 2. Define Payload Types

For each async operation, define a payload struct that holds the parsed arguments:

```zig
// In Worker.zig or a new async_payloads.zig file
pub const FetchPayload = struct {
    url: []const u8,  // Owned, will be freed by worker
};

pub const SimulateWorkPayload = struct {
    delay_ms: u64,
};
```

### 3. Define Binding Specs for Async Operations

```zig
const async_bindings = [_]BindingSpec{
    .{
        .name = "fetch",
        .zig_func_name = "N/A", // Not used for async
        .kind = .static,
        .args = &.{.string}, // Just the URL
        .return_type = .{ .promise = .{
            .payload_type = "Worker.FetchPayload",
            .worker_func = "Worker.workerFetchHTTP",
        }},
    },
    .{
        .name = "simulateWork",
        .zig_func_name = "N/A",
        .kind = .static,
        .args = &.{.int32}, // delay_ms
        .return_type = .{ .promise = .{
            .payload_type = "Worker.SimulateWorkPayload",
            .worker_func = "Worker.workerSimulate",
        }},
    },
};
```

### 4. Code Generation Pattern

For a `.promise` return type, gen_bindings.zig generates:

```zig
// Generated parse function
fn parse_fetch(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.FetchPayload {
    if (args.len < 1) return ctx.throwTypeError("fetch requires 1 argument");

    const url_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(url_str);

    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;
    const url_copy = try loop.allocator.dupe(u8, std.mem.span(url_str));

    return Worker.FetchPayload{ .url = url_copy };
}

// Use bindAsync to create the binding
pub const js_fetch = async_bridge.bindAsync(
    Worker.FetchPayload,
    parse_fetch,
    Worker.workerFetchHTTP,
);
```

### 5. Worker Functions

Worker functions remain handwritten in Worker.zig:

```zig
// Worker.zig
pub fn workerFetchHTTP(allocator: std.mem.Allocator, payload: FetchPayload) ![]u8 {
    defer allocator.free(payload.url);

    // Do the actual work...
    const result = try zexplore_example_com(allocator, payload.url);
    return result;
}
```

## Benefits

1. **Eliminates boilerplate**: All the Promise creation, error handling, worker spawning is auto-generated
2. **Type safety**: Payload types are strongly typed
3. **Separation of concerns**:
   - Parser (main thread) - auto-generated
   - Worker (background thread) - handwritten domain logic
4. **Consistent error handling**: All async bindings handle errors the same way
5. **Easy to add new async operations**: Just define payload type, worker function, and binding spec

## Implementation Steps

1. Add `.promise` variant to `ReturnType` in gen_bindings.zig
2. Add `generateAsyncBinding()` function to generate parse functions
3. Create `async_payloads.zig` for payload type definitions
4. Refactor `Worker.workerFetchHTTP` and `Worker.workerSimulate` to match the signature:
   ```zig
   fn(allocator: std.mem.Allocator, payload: PayloadType) ![]u8
   ```
5. Generate `pub const js_fetch = async_bridge.bindAsync(...)` statements

## Example: Complete Generated Code

```zig
// === Generated in bindings_generated.zig ===

const async_bridge = @import("async_bridge.zig");
const Worker = @import("Worker.zig");

// Parse function for fetch
fn parse_fetch(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;

    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;
    const url_str = try ctx.toZString(args[0]);
    const url_copy = try loop.allocator.dupe(u8, url_str);

    return .{ .url = url_copy };
}

// Binding using async_bridge
pub const js_fetch = async_bridge.bindAsync(
    Worker.FetchPayload,
    parse_fetch,
    Worker.workerFetchHTTP,
);

// Parse function for simulateWork
fn parse_simulateWork(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.SimulateWorkPayload {
    if (args.len < 1) return error.InvalidArgCount;

    const delay_ms = try ctx.toInt32(args[0]);
    return .{ .delay_ms = @intCast(delay_ms) };
}

// Binding
pub const js_simulateWork = async_bridge.bindAsync(
    Worker.SimulateWorkPayload,
    parse_simulateWork,
    Worker.workerSimulate,
);
```

## Migration Path

1. Keep current manual bindings in utils.zig for now
2. Implement async binding generation in gen_bindings.zig
3. Test generated bindings work identically
4. Replace manual bindings with generated ones
5. Remove utils.zig or repurpose for utilities only
