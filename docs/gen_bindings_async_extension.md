# Extending gen_bindings.zig for Async Operations

## Goal

Auto-generate async bindings using [async_bridge.zig](../src/async_bridge.zig), eliminating even the parse function boilerplate.

## Current State

✅ **What we have**:
- `async_bridge.bindAsync()` - generic framework for async bindings
- Payload types in [Worker.zig](../src/Worker.zig)
- Worker functions with correct signature
- Manual example in [async_bindings_example.zig](../src/async_bindings_example.zig)

❌ **What's still manual**:
- Parse functions (~15 lines each)
- Binding declarations
- Installation code

## Proposed Extension to gen_bindings.zig

### 1. Add AsyncBindingSpec

```zig
const AsyncBindingSpec = struct {
    name: []const u8,              // JS function name
    args: []const AsyncArgType,    // Argument types
    payload_type: []const u8,      // e.g., "Worker.FetchPayload"
    worker_func: []const u8,       // e.g., "Worker.workerFetch"
};

const AsyncArgType = union(enum) {
    string,   // Maps to []const u8 in payload
    int32,    // Maps to i32 in payload
    uint32,   // Maps to u32 in payload
    boolean,  // Maps to bool in payload
};
```

### 2. Define Async Bindings

```zig
const async_bindings = [_]AsyncBindingSpec{
    .{
        .name = "fetch",
        .args = &.{.string},
        .payload_type = "Worker.FetchPayload",
        .worker_func = "Worker.workerFetch",
    },
    .{
        .name = "simulateWork",
        .args = &.{.int32},
        .payload_type = "Worker.SimulateWorkPayload",
        .worker_func = "Worker.workerSimulateAsync",
    },
};
```

### 3. Code Generation Logic

The generator needs to produce:

#### A. Parse Function

```zig
fn parse_fetch(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;

    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;

    // Generate argument extraction based on spec.args
    const url_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(url_str);
    const url_copy = try loop.allocator.dupe(u8, std.mem.span(url_str));

    return .{ .url = url_copy };
}
```

#### B. Binding Declaration

```zig
pub const js_fetch = async_bridge.bindAsync(
    Worker.FetchPayload,
    parse_fetch,
    Worker.workerFetch,
);
```

#### C. Installation Code

```zig
pub fn installAsyncBindings(ctx: zqjs.Context, global: zqjs.Object) !void {
    try global.setFunction("fetch", js_fetch, 1);
    try global.setFunction("simulateWork", js_simulateWork, 1);
}
```

### 4. Implementation Sketch

```zig
fn generateAsyncBindings(writer: anytype, bindings: []const AsyncBindingSpec) !void {
    // Generate imports
    try writer.writeAll(
        \\const async_bridge = @import("async_bridge.zig");
        \\const Worker = @import("Worker.zig");
        \\const EventLoop = @import("event_loop.zig").EventLoop;
        \\
        \\
    );

    // Generate parse functions
    for (bindings) |spec| {
        try generateParseFunction(writer, spec);
    }

    // Generate binding declarations
    try writer.writeAll("// Async bindings\n");
    for (bindings) |spec| {
        try writer.print(
            \\pub const js_{s} = async_bridge.bindAsync(
            \\    {s},
            \\    parse_{s},
            \\    {s},
            \\);
            \\
            \\
        , .{ spec.name, spec.payload_type, spec.name, spec.worker_func });
    }

    // Generate installer
    try writer.writeAll(
        \\pub fn installAsyncBindings(ctx: zqjs.Context, global: zqjs.Object) !void {
        \\
    );
    for (bindings) |spec| {
        try writer.print(
            \\    try global.setFunction("{s}", js_{s}, {d});
            \\
        , .{ spec.name, spec.name, spec.args.len });
    }
    try writer.writeAll("}\n");
}

fn generateParseFunction(writer: anytype, spec: AsyncBindingSpec) !void {
    try writer.print(
        \\fn parse_{s}(ctx: zqjs.Context, args: []const zqjs.Value) !{s} {{
        \\    if (args.len < {d}) return error.InvalidArgCount;
        \\
        \\    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;
        \\
        \\
    , .{ spec.name, spec.payload_type, spec.args.len });

    // Generate argument extraction based on type
    for (spec.args, 0..) |arg_type, i| {
        switch (arg_type) {
            .string => {
                try writer.print(
                    \\    const arg{d}_str = try ctx.toCString(args[{d}]);
                    \\    defer ctx.freeCString(arg{d}_str);
                    \\    const arg{d}_copy = try loop.allocator.dupe(u8, std.mem.span(arg{d}_str));
                    \\
                , .{ i, i, i, i, i });
            },
            .int32 => {
                try writer.print(
                    \\    const arg{d} = try ctx.toInt32(args[{d}]);
                    \\
                , .{ i, i });
            },
            .uint32 => {
                try writer.print(
                    \\    const arg{d} = try ctx.toUint32(args[{d}]);
                    \\
                , .{ i, i });
            },
            .boolean => {
                try writer.print(
                    \\    const arg{d} = ctx.toBool(args[{d}]);
                    \\
                , .{ i, i });
            },
        }
    }

    // TODO: Generate return statement based on payload field names
    // For now, this assumes payload has fields in order: arg0, arg1, etc.
    try writer.writeAll("    return .{ /* TODO: map args to payload fields */ };\n");
    try writer.writeAll("}\n\n");
}
```

## Challenges

### Challenge 1: Payload Field Names

The generator needs to know the field names in the payload struct. Options:

**Option A**: Use comptime reflection
```zig
// Use @typeInfo to inspect Worker.FetchPayload and map args to fields
const payload_fields = @typeInfo(Worker.FetchPayload).Struct.fields;
```

**Option B**: Require field names in spec
```zig
const AsyncBindingSpec = struct {
    // ...
    payload_fields: []const []const u8, // ["url"], ["delay_ms"], etc.
};
```

**Option C**: Convention-based naming
```zig
// Assume payload fields are named: arg0, arg1, arg2, ...
return .{ .arg0 = arg0_copy, .arg1 = arg1, };
```

**Recommendation**: Use Option A (reflection) for maximum type safety.

### Challenge 2: Memory Ownership

Different types have different ownership semantics:
- **Strings**: Must be duplicated (owned by worker)
- **Integers/Booleans**: Copied by value
- **Complex types**: May need deep copy

The generator needs to handle this correctly.

### Challenge 3: Error Messages

Parse functions should provide helpful error messages:
```zig
if (args.len < 1) return ctx.throwTypeError("fetch requires 1 argument (url)");
```

The generator should include the function name and expected arguments in errors.

## Incremental Implementation Plan

### Phase 1: Basic String Arguments ✅
- Support single string argument
- Generate parse function
- Generate binding declaration
- **Status**: Can implement now with current tools

### Phase 2: Multiple Argument Types
- Support int32, uint32, boolean
- Handle type conversion errors
- Generate proper error messages

### Phase 3: Payload Field Mapping
- Use comptime reflection to map args to payload fields
- Support custom field names
- Validate payload struct matches args

### Phase 4: Advanced Types
- Support optional arguments
- Support array/object arguments
- Support custom validators

### Phase 5: Integration
- Merge async bindings into main gen_bindings.zig
- Update build.zig to generate both sync and async bindings
- Deprecate manual bindings in utils.zig

## Example Output

Given this spec:
```zig
.{
    .name = "fetch",
    .args = &.{.string},
    .payload_type = "Worker.FetchPayload",
    .worker_func = "Worker.workerFetch",
}
```

Generate:
```zig
fn parse_fetch(ctx: zqjs.Context, args: []const zqjs.Value) !Worker.FetchPayload {
    if (args.len < 1) return error.InvalidArgCount;

    const loop = EventLoop.getFromContext(ctx) orelse return error.NoEventLoop;

    const arg0_str = try ctx.toCString(args[0]);
    defer ctx.freeCString(arg0_str);
    const url = try loop.allocator.dupe(u8, std.mem.span(arg0_str));

    return .{ .url = url };
}

pub const js_fetch = async_bridge.bindAsync(
    Worker.FetchPayload,
    parse_fetch,
    Worker.workerFetch,
);
```

## Next Steps

1. **Implement basic code generation** in gen_bindings.zig for single-string-arg async functions
2. **Test** with fetch and simulateWork examples
3. **Extend** to support multiple arguments and types
4. **Add comptime reflection** to map arguments to payload fields automatically
5. **Document** the new async binding workflow

## Benefits

Once complete:
- **Zero boilerplate** for async bindings
- **Type safety** enforced at compile time
- **Consistent error handling** across all bindings
- **Easy to add new async operations** - just define payload, worker, and spec entry

## Files to Modify

- [tools/gen_bindings.zig](../tools/gen_bindings.zig): Add async binding generation
- [build.zig](../build.zig): Update to generate async bindings
- [src/Worker.zig](../src/Worker.zig): Keep as payload + worker definitions
- [src/utils.zig](../src/utils.zig): Eventually deprecate manual bindings
