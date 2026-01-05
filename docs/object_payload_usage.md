# Object Payload Usage Guide

The `auto_bridge.zig` now supports **two calling conventions** automatically:

## Mode 1: Positional Arguments (Original)

```javascript
// JavaScript: Pass arguments in order
readFile("test.txt")
```

```zig
// Zig: Define payload struct
const ReadFilePayload = struct {
    path: []const u8,  // Maps to arg[0]
};
```

## Mode 2: Object Arguments (New!)

```javascript
// JavaScript: Pass a single object with named properties
writeFile({
    path: "output.txt",
    content: "Hello World",
    mode: 0o644
})
```

```zig
// Zig: Same payload struct!
const WriteFilePayload = struct {
    path: []const u8,    // Maps to obj.path
    content: []const u8, // Maps to obj.content
    mode: u32,           // Maps to obj.mode
};
```

## How It Works

The parser **automatically detects** which mode to use:

```
If args.len == 1 AND args[0] is an object:
    → Object mode: Parse properties from the object
Else:
    → Positional mode: Map args[i] to field[i]
```

## Complete Example: writeFile

### 1. Define the Payload and Worker

```zig
// In Worker.zig
const WriteFilePayload = struct {
    path: []const u8,
    content: []const u8,
    mode: u32,
};

pub fn workerWriteFile(allocator: std.mem.Allocator, payload: WriteFilePayload) ![]u8 {
    // ⚠️ CRITICAL: Free all string fields!
    defer allocator.free(payload.path);
    defer allocator.free(payload.content);

    const file = try std.fs.cwd().createFile(payload.path, .{ .mode = payload.mode });
    defer file.close();
    try file.writeAll(payload.content);

    return try std.fmt.allocPrint(
        allocator,
        "Wrote {d} bytes to {s}",
        .{ payload.content.len, payload.path },
    );
}
```

### 2. Register the Binding

```zig
// In tools/gen_async_bindings.zig
const async_bindings = [_]AsyncBindingSpec{
    // ... existing bindings ...
    .{
        .name = "writeFile",
        .payload_type = "Worker.WriteFilePayload",
        .worker_func = "Worker.workerWriteFile",
        .arg_count = 1,  // ← Note: 1 because we expect an object!
    },
};
```

### 3. Regenerate Bindings

```bash
zig run tools/gen_async_bindings.zig -- src/async_bindings_generated.zig
zig build
```

### 4. Use from JavaScript

```javascript
// Style 1: Object (Recommended for multiple parameters)
writeFile({
    path: "output.txt",
    content: "Hello, World!",
    mode: 0o644
})
  .then(result => console.log(result))
  .catch(err => console.error(err));

// Style 2: Positional (Still works if you pass 3 arguments!)
writeFile("output.txt", "Hello, World!", 0o644)
  .then(result => console.log(result))
  .catch(err => console.error(err));
```

## When to Use Each Mode

### Use Object Mode When:

✅ **3+ parameters** - More readable with named properties
```javascript
createUser({
    name: "Alice",
    email: "alice@example.com",
    age: 30,
    role: "admin"
})
```

✅ **Order independence matters**
```javascript
// These are equivalent!
updateSettings({ theme: "dark", lang: "en" })
updateSettings({ lang: "en", theme: "dark" })
```

✅ **Building APIs** - More self-documenting
```javascript
httpRequest({
    url: "https://api.example.com",
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: '{"key":"value"}'
})
```

### Use Positional Mode When:

✅ **1-2 simple parameters**
```javascript
readFile("test.txt")
sleep(1000)
```

✅ **Order is obvious**
```javascript
add(5, 3)  // Clear: 5 + 3
```

## Type Support

Both modes support the same types:

| Type | Example |
|------|---------|
| **Integers** | `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `usize`, `isize` |
| **Floats** | `f32`, `f64` |
| **Strings** | `[]const u8`, `[]u8` |
| **Booleans** | `bool` |

## Error Handling

### Object Mode Errors

```javascript
// Missing required property
writeFile({ path: "test.txt" })  // ❌ Missing 'content' and 'mode'
// → TypeError: Missing required property: content

// Wrong type
writeFile({ path: 123, content: "hello", mode: 0o644 })  // ❌ path not string
// → TypeError: Expected string
```

### Positional Mode Errors

```javascript
// Not enough arguments
writeFile("test.txt")  // ❌ Needs 3 args
// → TypeError: Not enough arguments

// Wrong type
writeFile(123, "hello", 0o644)  // ❌ First arg not string
// → TypeError: Expected string
```

## Memory Contract (CRITICAL!)

**Regardless of calling convention**, the memory contract is the same:

```zig
pub fn workerWriteFile(allocator: std.mem.Allocator, payload: WriteFilePayload) ![]u8 {
    // ⚠️ MUST free ALL string fields allocated by AutoBridge!
    defer allocator.free(payload.path);
    defer allocator.free(payload.content);

    // Your logic here...

    return result;  // You own the returned string too
}
```

AutoBridge allocates strings whether they come from:
- Positional args: `writeFile("a.txt", "hello", 0o644)`
- Object properties: `writeFile({ path: "a.txt", content: "hello", mode: 0o644 })`

**You must free them either way!**

## Advanced: Mixed Payloads

You can have payloads with different types:

```zig
const ComplexPayload = struct {
    url: []const u8,      // String (allocated)
    timeout: u32,         // Integer (stack value)
    retries: u8,          // Integer (stack value)
    debug: bool,          // Boolean (stack value)
    scale: f64,           // Float (stack value)
};
```

```javascript
// Object mode
fetch({
    url: "https://example.com",
    timeout: 5000,
    retries: 3,
    debug: true,
    scale: 1.5
})

// Positional mode (order must match struct field order!)
fetch("https://example.com", 5000, 3, true, 1.5)
```

**Memory rule**: Only free string fields (`[]const u8`, `[]u8`). Other types are stack values.

```zig
fn workerFetch(allocator: std.mem.Allocator, payload: ComplexPayload) ![]u8 {
    defer allocator.free(payload.url);  // ← Only free the string!
    // timeout, retries, debug, scale are NOT freed (stack values)

    // Your logic...
}
```

## Best Practices

1. **Prefer object mode for 3+ params**
   ```javascript
   // Good
   createPost({ title: "...", body: "...", author: "...", tags: [...] })

   // Bad (hard to remember order)
   createPost("...", "...", "...", [...])
   ```

2. **Use positional for simple cases**
   ```javascript
   // Good
   sleep(1000)

   // Overkill
   sleep({ milliseconds: 1000 })
   ```

3. **Document expected format**
   ```javascript
   /**
    * Write a file to disk
    * @param {Object} options
    * @param {string} options.path - File path
    * @param {string} options.content - File content
    * @param {number} options.mode - Unix file permissions (e.g., 0o644)
    */
   function writeFile(options) { ... }
   ```

## Implementation Details

The detection logic is simple:

```zig
if (args.len == 1 and ctx.isObject(args[0])) {
    // Object mode: Extract properties by name
    for (fields) |field| {
        const prop = ctx.getPropertyStr(obj, field.name);
        // ... convert prop to field type
    }
} else {
    // Positional mode: Map args[i] to field[i]
    for (fields, 0..) |field, i| {
        const arg = args[i];
        // ... convert arg to field type
    }
}
```

This means:
- **Zero runtime overhead** if you use positional mode (no object detection)
- **One property lookup per field** if you use object mode
- **Automatic** - no configuration needed!

## Summary

✅ **Object mode**: Pass `{ prop: value, ... }` for readable APIs
✅ **Positional mode**: Pass `arg1, arg2, ...` for simple cases
✅ **Automatic detection**: No configuration needed
✅ **Same memory contract**: Free all string fields in your worker
✅ **Type-safe**: Compile-time validation of struct fields

Now your async bindings are even more ergonomic! 🎉
