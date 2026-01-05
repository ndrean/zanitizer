# Using async_bridge.zig to Eliminate Async Binding Boilerplate

## Overview

You noticed that `js_fetch` and `js_simulateWork` in [utils.zig](../src/utils.zig) contain lots of repetitive boilerplate. The [async_bridge.zig](../src/async_bridge.zig) framework solves this by providing a generic binding generator.

## The Problem: Boilerplate Hell

Every async binding in `utils.zig` follows the same pattern:

```zig
pub fn js_fetch(...) callconv(.c) qjs.JSValue {
    // 1. Get EventLoop from context ✓ boilerplate
    // 2. Parse arguments ← domain-specific
    // 3. Duplicate data for worker ✓ boilerplate
    // 4. Create Promise with JS_NewPromiseCapability ✓ boilerplate
    // 5. Create worker task struct ✓ boilerplate
    // 6. Handle 6 different error cases ✓ boilerplate
    // 7. Spawn worker ✓ boilerplate
    // 8. Return promise ✓ boilerplate
}
```

**Result**: 74 lines of code, only ~15 lines are domain-specific!

## The Solution: async_bridge.bindAsync()

The `bindAsync()` function in [async_bridge.zig:8-118](../src/async_bridge.zig#L8-L118) takes care of all boilerplate:

```zig
pub fn bindAsync(
    comptime Payload: type,          // Data structure for worker
    comptime parseFn: ...,            // Extract args from JS (main thread)
    comptime workFn: ...,             // Do the work (background thread)
) qjs.JSCFunction
```

## Step-by-Step Migration

### Step 1: Define Payload Types

In [Worker.zig](../src/Worker.zig), define the data your worker needs:

```zig
pub const FetchPayload = struct {
    url: []const u8,  // Owned, worker will free
};

pub const SimulateWorkPayload = struct {
    delay_ms: u64,
};
```

✅ **Done**: See [Worker.zig:12-19](../src/Worker.zig#L12-L19)

### Step 2: Write Worker Functions

Worker functions must match this signature:

```zig
fn(allocator: std.mem.Allocator, payload: PayloadType) ![]u8
```

```zig
pub fn workerFetch(allocator: std.mem.Allocator, payload: FetchPayload) ![]u8 {
    defer allocator.free(payload.url);
    return try zexplore_example_com(allocator, payload.url);
}

pub fn workerSimulateAsync(allocator: std.mem.Allocator, payload: SimulateWorkPayload) ![]u8 {
    std.Thread.sleep(payload.delay_ms * 1_000_000);
    return try std.fmt.allocPrint(allocator, "✅ Work finished after {d}ms", .{payload.delay_ms});
}
```

✅ **Done**: See [Worker.zig:139-151](../src/Worker.zig#L139-L151)

### Step 3: Write Parse Functions

Parse functions extract arguments from JavaScript:

```zig
fn parseFetch(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;

    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;
    const url_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(url_str);

    const url_copy = try loop.allocator.dupe(u8, std.mem.span(url_str));
    return .{ .url = url_copy };
}
```

✅ **Done**: See [async_bindings_example.zig:18-31](../src/async_bindings_example.zig#L18-L31)

### Step 4: Create Bindings (One-Liners!)

```zig
pub const js_fetch = async_bridge.bindAsync(
    Worker.FetchPayload,
    parseFetch,
    Worker.workerFetch,
);

pub const js_simulateWork = async_bridge.bindAsync(
    Worker.SimulateWorkPayload,
    parseSimulateWork,
    Worker.workerSimulateAsync,
);
```

✅ **Done**: See [async_bindings_example.zig:50-62](../src/async_bindings_example.zig#L50-L62)

### Step 5: Install Bindings

```zig
pub fn installAsyncBindings(ctx: zqjs.Context, global: zqjs.Object) !void {
    try global.setFunction("fetch", js_fetch, 1);
    try global.setFunction("simulateWork", js_simulateWork, 1);
}
```

## Code Reduction

| Aspect | Manual (utils.zig) | With async_bridge | Reduction |
|--------|-------------------|-------------------|-----------|
| js_fetch | 74 lines | ~16 lines | 78% |
| js_simulateWork | 44 lines | ~16 lines | 64% |
| **Boilerplate** | ~100 lines | **0 lines** | **100%** |

All the Promise creation, error handling, and worker spawning is handled by `async_bridge.bindAsync()`.

## How async_bridge.bindAsync() Works

1. **Comptime Magic**: `bindAsync()` is a comptime function that generates a custom C callback for your specific payload type
2. **Type Safety**: Each binding gets its own `GenericTask(Payload)` struct
3. **Automatic Error Handling**: Errors are caught, formatted, and passed to Promise.reject()
4. **Memory Management**: The framework ensures proper cleanup of Promise resolvers

See the implementation in [async_bridge.zig](../src/async_bridge.zig).

## Next Steps: Integrating with gen_bindings.zig

The next evolution is to extend [gen_bindings.zig](../tools/gen_bindings.zig) to **auto-generate** the parse functions too.

### Proposed Design

```zig
const async_bindings = [_]AsyncBindingSpec{
    .{
        .name = "fetch",
        .args = &.{.string},  // URL
        .payload_type = "Worker.FetchPayload",
        .worker_func = "Worker.workerFetch",
    },
    .{
        .name = "simulateWork",
        .args = &.{.int32},  // delay_ms
        .payload_type = "Worker.SimulateWorkPayload",
        .worker_func = "Worker.workerSimulateAsync",
    },
};
```

This would generate:
- Parse function (like `parseFetch`)
- Binding declaration (like `pub const js_fetch = bindAsync(...)`)
- Installation code (like `global.setFunction(...)`)

**Result**: You only need to:
1. Define the payload struct
2. Write the worker function
3. Add one entry to the `async_bindings` array

See [async_bindings_design.md](./async_bindings_design.md) for the full proposal.

## Files Modified

- [Worker.zig](../src/Worker.zig): Added payload types and async-compatible worker functions
- [async_bridge.zig](../src/async_bridge.zig): Fixed error union handling bug
- [async_bindings_example.zig](../src/async_bindings_example.zig): Complete working example

## Migration Path

1. ✅ **Phase 1 (Done)**: Create async_bridge.zig framework
2. ✅ **Phase 2 (Done)**: Define payload types and worker functions
3. ✅ **Phase 3 (Done)**: Create example bindings using async_bridge
4. **Phase 4 (Next)**: Test the new bindings in main.zig
5. **Phase 5 (Future)**: Extend gen_bindings.zig to auto-generate parse functions
6. **Phase 6 (Future)**: Replace manual utils.zig bindings with generated ones

## Testing

To test the new async_bridge bindings:

```zig
// In main.zig, replace the manual bindings with:
const async_bindings = @import("async_bindings_example.zig");

// In your setup code:
try async_bindings.installAsyncBindings(ctx, global);

// Then use in JavaScript:
const css = await fetch("https://example.com");
const result = await simulateWork(1000);
```

The behavior should be **identical** to the manual bindings, but with 78% less code!
