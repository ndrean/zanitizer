# Object Payloads in Auto Bridge

## The Problem

Currently, `auto_bridge.zig` maps struct fields to positional JS arguments:

```zig
const Payload = struct {
    path: []const u8,    // JS arg[0]
    content: []const u8, // JS arg[1]
};

// JavaScript: writeFile("test.txt", "hello")
```

But what if you want to pass a **JavaScript object** instead?

```javascript
// JavaScript: writeFile({ path: "test.txt", content: "hello" })
```

## Solution: Two Modes

Auto-bridge can support **two modes**:

### Mode 1: Positional Arguments (Current)
```zig
const Payload = struct {
    path: []const u8,
    content: []const u8,
};

// JS: writeFile("test.txt", "hello")
//     field[0] ← arg[0], field[1] ← arg[1]
```

### Mode 2: Single Object Argument (New)
```zig
const Payload = struct {
    path: []const u8,
    content: []const u8,
};

// JS: writeFile({ path: "test.txt", content: "hello" })
//     Extract properties from args[0] object
```

## Implementation Strategy

### Detection Logic

```zig
// In AutoParser.parse():
const fields = std.meta.fields(Payload);

if (args.len == 1 and ctx.isObject(args[0])) {
    // Mode 2: Parse object properties
    return try parseFromObject(loop, ctx, args[0]);
} else {
    // Mode 1: Parse positional arguments (current behavior)
    return try parseFromPositional(loop, ctx, args);
}
```

### Mode 2 Implementation

```zig
fn parseFromObject(loop: *EventLoop, ctx: zqjs.Context, obj: zqjs.Value) !Payload {
    const fields = std.meta.fields(Payload);
    var payload: Payload = undefined;

    inline for (fields) |field| {
        // Get property from JS object
        const prop = try ctx.getPropertyStr(obj, field.name);
        defer ctx.freeValue(prop);

        // Convert based on type
        const T = field.type;
        if (comptime isStringType(T)) {
            @field(payload, field.name) = try parseString(loop, ctx, prop);
        } else if (comptime isIntegerType(T)) {
            @field(payload, field.name) = try parseInteger(T, ctx, prop);
        }
        // ... other types
    }

    return payload;
}
```

## Example Usage

```zig
// Define payload
const WriteFilePayload = struct {
    path: []const u8,
    content: []const u8,
    mode: u32,
};

// Worker function
fn doWriteFile(allocator: std.mem.Allocator, task: WriteFilePayload) ![]u8 {
    defer allocator.free(task.path);
    defer allocator.free(task.content);

    const file = try std.fs.cwd().createFile(task.path, .{ .mode = task.mode });
    defer file.close();
    try file.writeAll(task.content);

    return try std.fmt.allocPrint(allocator, "Wrote {d} bytes", .{task.content.len});
}

// Binding
pub const js_writeFile = AutoBridge.bindAsyncAuto(WriteFilePayload, doWriteFile);
```

```javascript
// JavaScript - Both styles work!

// Style 1: Positional (if 3 args provided)
writeFile("test.txt", "Hello World", 0o644)

// Style 2: Object (if 1 object arg provided)
writeFile({
    path: "test.txt",
    content: "Hello World",
    mode: 0o644
})
```

## Benefits of Object Mode

1. **Named parameters** - Clearer API, order doesn't matter
2. **Optional fields** - Can add `?` optional fields in Zig
3. **Better JavaScript ergonomics** - Standard JS pattern
4. **Extensibility** - Easy to add new fields without breaking existing calls

## Memory Contract

**Same rules apply!** AutoBridge allocates strings in object mode too:

```zig
fn doWork(allocator: std.mem.Allocator, task: Payload) ![]u8 {
    // MUST free ALL string fields from the object!
    defer allocator.free(task.path);
    defer allocator.free(task.content);
    // ...
}
```

## Trade-offs

**Positional Mode:**
- ✅ Simpler for few arguments
- ✅ Slightly faster (no property lookup)
- ❌ Order-dependent
- ❌ Unclear what each argument means

**Object Mode:**
- ✅ Self-documenting API
- ✅ Order-independent
- ✅ Better for many parameters
- ❌ Slightly more overhead (property lookups)

## Recommendation

For **async bindings with 3+ parameters**, use object mode:

```javascript
// Good: Clear what each parameter means
createUser({
    name: "Alice",
    email: "alice@example.com",
    age: 30,
    admin: false
})

// Bad: What does each argument mean?
createUser("Alice", "alice@example.com", 30, false)
```

For **1-2 parameters**, positional is fine:

```javascript
// Simple and clear
readFile("test.txt")
simulateWork(1000)
```

## Next Steps

To implement this, we need to:

1. Add `ctx.getPropertyStr()` wrapper method (if not exists)
2. Add object detection to `AutoParser.parse()`
3. Implement `parseFromObject()` helper
4. Update tests and documentation

Would you like me to implement object payload support in auto_bridge.zig?
