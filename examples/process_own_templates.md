# Processing Your Own Templates with Event Handlers

## Problem

You have your own Alpine.js/Vue/HTMX templates that contain event handlers:

```html
<!-- Your Alpine.js template -->
<div x-data="{ open: false }">
    <button x-on:click="open = !open">Toggle</button>
    <div x-show="open">Content</div>
</div>

<!-- Your HTMX template -->
<button hx-get="/api/data" hx-on:htmx:afterRequest="console.log('done')">
    Load Data
</button>
```

By default, the sanitizer blocks event handlers (`x-on:*`, `hx-on:*`, etc.) for security. But **this is YOUR code** - you want to keep those handlers!

## Solution: Use `bypassSafety`

### Option 1: Use `.trusted()` preset (Recommended)

```zig
const std = @import("std");
const z = @import("root");

// For YOUR OWN templates with event handlers
const sanitizer = try z.Sanitizer.initTrusted(allocator);
defer sanitizer.deinit();

// Now process your own HTML
const your_template =
    \\<div x-data="{ count: 0 }">
    \\  <button x-on:click="count++">Increment</button>
    \\  <span x-text="count"></span>
    \\</div>
;

// TODO: Integration with parsing API
// const doc = try z.parseHTMLWithSanitizer(allocator, your_template, sanitizer);
```

### Option 2: Use `.none()` preset (No sanitization)

```zig
// Completely skip sanitization for YOUR code
const sanitizer = try z.Sanitizer.initNone(allocator);
defer sanitizer.deinit();

// Process your own templates without any filtering
```

### Option 3: Custom config with `bypassSafety`

```zig
// Allow Alpine.js with event handlers, but still filter some things
const config = z.SanitizerConfig{
    .bypassSafety = true, // ⚠️ Allows event handlers!
    .frameworks = .{
        .allow_alpine = true,
        .allow_vue = false,    // Block Vue even though bypassSafety = true
        .allow_htmx = true,
    },
    .removeElements = &[_][]const u8{ "script" }, // Still block <script>
};

const sanitizer = try z.Sanitizer.init(allocator, config);
defer sanitizer.deinit();
```

## What `bypassSafety` Does

When `bypassSafety = true`:

✅ **Allows** event handlers:
- `onclick`, `onerror`, `onload` (HTML)
- `x-on:click`, `x-on:submit` (Alpine.js)
- `@click`, `@submit` (Vue.js)
- `v-on:click` (Vue.js)
- `hx-on:*` (HTMX)
- `phx-click`, `phx-submit` (Phoenix)
- `(click)`, `(submit)` (Angular)
- `on:click` (Svelte)

✅ **Still respects** framework configuration:
- If `allow_vue = false`, then `v-if`, `v-for` are blocked
- But `@click` is allowed (because it's an event handler and bypassSafety = true)

## Use Cases

### ✅ Good: Your own templates

```zig
// Processing your Alpine.js component library
const config = z.SanitizerConfig.trusted();

// Your own Vue.js templates
const config = z.SanitizerConfig.trusted();

// Your own HTMX fragments
const config = z.SanitizerConfig.trusted();
```

### ❌ Bad: User-generated content

```zig
// NEVER use bypassSafety for user input!
const user_html = get_user_comment(); // From database
const config = z.SanitizerConfig.trusted(); // ❌ DANGER!

// Use default or strict instead:
const config = z.SanitizerConfig.default(); // ✅ Safe
```

## Comparison

| Config | Event Handlers | Framework Attrs | Scripts | Use Case |
|--------|---------------|-----------------|---------|----------|
| `.default()` | ❌ Blocked | ✅ Allowed | ❌ Blocked | User content with frameworks |
| `.strict()` | ❌ Blocked | ❌ Blocked | ❌ Blocked | Untrusted user content |
| `.permissive()` | ❌ Blocked | ✅ Allowed | ❌ Blocked | Trusted editors (CMS) |
| `.trusted()` | ✅ **Allowed** | ✅ Allowed | ✅ Allowed | **YOUR OWN code** |
| `.none()` | ✅ **Allowed** | ✅ Allowed | ✅ Allowed | **No sanitization** |

## When to Use Each Mode

```zig
// User comments on a blog
const blog_config = z.SanitizerConfig.strict();

// CMS content from trusted editors
const cms_config = z.SanitizerConfig.default();

// Your own Alpine.js component library
const component_config = z.SanitizerConfig.trusted(); // ← Use this!

// Your own internal admin templates
const admin_config = z.SanitizerConfig.none(); // ← Or this!
```

## Security Warning

⚠️ **NEVER** use `bypassSafety = true` for:
- User-generated content
- External HTML sources
- Anything from a database that users can write to
- API responses from external services

Only use it for HTML that YOU wrote and control 100%.

## Example: Alpine.js Component Library

```zig
const std = @import("std");
const z = @import("root");

pub fn loadComponents(allocator: std.mem.Allocator) !void {
    // Your component templates (YOU wrote these)
    const dropdown_component =
        \\<div x-data="{ open: false }" class="dropdown">
        \\  <button x-on:click="open = !open">Menu</button>
        \\  <div x-show="open" x-on:click.away="open = false">
        \\    <slot></slot>
        \\  </div>
        \\</div>
    ;

    const modal_component =
        \\<div x-data="{ show: false }">
        \\  <button x-on:click="show = true">Open Modal</button>
        \\  <div x-show="show" x-on:keydown.escape="show = false">
        \\    <slot></slot>
        \\  </div>
        \\</div>
    ;

    // Use trusted config for YOUR components
    const sanitizer = try z.Sanitizer.initTrusted(allocator);
    defer sanitizer.deinit();

    // Process your component templates
    // They contain x-on:* handlers which would normally be blocked
    // But with bypassSafety = true, they're allowed
    std.debug.print("Processing your own Alpine.js components...\n", .{});
    std.debug.print("Event handlers are allowed: {}\n", .{sanitizer.config.bypassSafety});
}
```

## Summary

- **Default behavior**: Event handlers blocked (safe for user content)
- **Your own code**: Use `bypassSafety = true` to allow event handlers
- **Presets**: `.trusted()` or `.none()` for your own templates
- **Security**: Never use for user-generated content!
