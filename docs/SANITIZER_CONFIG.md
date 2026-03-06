# SanitizerConfig - Web API-Compatible HTML Sanitization

## Overview

The `SanitizerConfig` module provides a runtime configuration layer for HTML sanitization that is compatible with the [Web Sanitizer API](https://wicg.github.io/sanitizer-api/). It sits on top of the static `html_spec.zig` (h5sc-compliant) to provide flexible, user-configurable sanitization.

## Architecture

```
┌────────────────────────────────────┐
│   SanitizerConfig (Runtime)        │  ← User configuration
│   - Framework settings             │
│   - Element/attribute filters      │
└────────────────────────────────────┘
                 ↓
┌────────────────────────────────────┐
│   html_spec.zig (Static)           │  ← h5sc compliance
│   - Valid HTML elements            │
│   - Safe attributes                │
│   - Validators (URI, CSS, etc.)    │
└────────────────────────────────────┘
```

**Key Principle**: The static `html_spec.zig` remains the ground truth for what's valid HTML. `SanitizerConfig` filters it at runtime based on user preferences.

## Quick Start

### 1. Default Configuration (Recommended)

```zig
const std = @import("std");
const z = @import("root");

// Default: Balanced security + framework support
const sanitizer = try z.Sanitizer.initDefault(allocator);
defer sanitizer.deinit();

// What it blocks:
// - script, iframe, object, embed elements
// - Event handlers: x-on:*, @click, v-on:*, etc.
// - Dangerous attributes: onclick, onerror, etc.

// What it allows:
// - Framework attributes: x-show, v-if, hx-get, phx-value-*
// - data-* and aria-* attributes
// - Custom elements (Web Components)
```

### 2. Strict Configuration (Maximum Security)

```zig
// Strict: Maximum security, no frameworks
const sanitizer = try z.Sanitizer.initStrict(allocator);
defer sanitizer.deinit();

// What it blocks:
// - script, style, iframe, object, embed
// - ALL framework attributes (x-*, v-*, hx-*, phx-*)
// - Custom elements
// - Comments

// What it allows:
// - Only basic HTML elements
// - aria-* attributes (accessibility)
// - Standard HTML attributes validated against html_spec
```

### 3. Permissive Configuration (Trusted Content)

```zig
// Permissive: For trusted content
const sanitizer = try z.Sanitizer.initPermissive(allocator);
defer sanitizer.deinit();

// What it blocks:
// - Only <script> elements
// - Event handlers (still blocked for security)

// What it allows:
// - style, iframe (with sandbox validation)
// - All framework attributes
// - Comments
// - Custom elements
```

### 4. Trusted Configuration (YOUR OWN Code)

```zig
// ⚠️ DANGER: For YOUR OWN trusted code that contains event handlers
const sanitizer = try z.Sanitizer.initTrusted(allocator);
defer sanitizer.deinit();

// What it blocks:
// - Nothing! (bypassSafety = true)

// What it allows:
// - Event handlers: onclick, x-on:*, @click, phx-click, etc.
// - All framework attributes including event handlers
// - All elements (scripts, iframes, etc.)
// - Any CSS in style attributes

// Use case: Processing your own templates with event handlers
// Example: Alpine.js templates with x-on:click='handleClick()'
```

### 5. None Configuration (No Sanitization)

```zig
// ⚠️ DANGER: NO sanitization at all - equivalent to old .none mode
const sanitizer = try z.Sanitizer.initNone(allocator);
defer sanitizer.deinit();

// Completely bypasses all checks
// Use ONLY for your own HTML that you trust 100%
```

## Framework Configuration

Control which framework attributes are allowed:

```zig
const config = z.SanitizerConfig{
    .frameworks = .{
        .allow_alpine = true,   // x-show, x-model, etc.
        .allow_vue = false,     // v-if, v-for (BLOCKED)
        .allow_htmx = true,     // hx-get, hx-post, etc.
        .allow_phoenix = true,  // phx-value-*, phx-update, etc.
        .allow_angular = false, // *ngIf, [prop] (BLOCKED)
        .allow_svelte = false,  // bind:value, use:action (BLOCKED)
    },
    .removeElements = &[_][]const u8{ "script", "iframe" },
};

const sanitizer = try z.Sanitizer.init(allocator, config);
defer sanitizer.deinit();

// Now you can use this sanitizer for your specific framework stack
```

**Important**: Event handlers are ALWAYS blocked (unless `bypassSafety = true`):
- `x-on:click` ❌ (blocked by default)
- `@click` ❌ (blocked by default)
- `v-on:submit` ❌ (blocked by default)
- `phx-click` ❌ (blocked by default)
- `(click)` ❌ (blocked by default)
- `on:click` ❌ (blocked by default)
- `onclick` ❌ (blocked by default)

**Exception**: When `bypassSafety = true` (trusted/none modes), event handlers ARE allowed ✅

Non-event framework attributes are allowed based on config:
- `x-show` ✅ (if allow_alpine = true)
- `v-if` ✅ (if allow_vue = true)
- `hx-get` ✅ (if allow_htmx = true)
- `phx-value-id` ✅ (if allow_phoenix = true)

## Web API Compatibility

### Element Filtering (Allowlist)

```zig
// Only allow specific elements
const config = z.SanitizerConfig{
    .elements = &[_][]const u8{ "div", "p", "span", "a", "strong", "em" },
};

try config.validate();

// div → allowed
// script → blocked
// table → blocked
```

### Element Filtering (Blocklist)

```zig
// Block specific elements
const config = z.SanitizerConfig{
    .removeElements = &[_][]const u8{ "script", "iframe", "embed" },
};

// div → allowed
// script → blocked
// table → allowed
```

### Attribute Filtering (Allowlist)

```zig
// Only allow specific attributes
const config = z.SanitizerConfig{
    .attributes = &[_][]const u8{ "class", "id", "href", "title" },
    .dataAttributes = true, // Also allow all data-* attributes
};

// class → allowed
// href → allowed
// data-id → allowed
// onclick → blocked (dangerous)
// style → blocked (not in list)
```

### Attribute Filtering (Blocklist)

```zig
// Block specific attributes
const config = z.SanitizerConfig{
    .removeAttributes = &[_][]const u8{ "style", "class" },
};

// href → allowed
// style → blocked
// class → blocked
```

### Validation Rules

```zig
// INVALID: Cannot use both allowlist and blocklist
const bad_config = z.SanitizerConfig{
    .elements = &[_][]const u8{ "div" },
    .removeElements = &[_][]const u8{ "script" }, // Error!
};

try config.validate(); // Returns error.InvalidConfig
```

## Advanced Features

### 1. Comments Control

```zig
const config = z.SanitizerConfig{
    .comments = true, // Allow HTML comments
};

// <!-- comment --> → kept
```

### 2. Custom Elements (Web Components)

```zig
const config = z.SanitizerConfig{
    .allowCustomElements = true, // Allow <my-component>
};

// <my-component> → allowed (if contains hyphen)
// <div> → allowed (standard HTML)
```

### 3. DOM Clobbering Protection

```zig
const config = z.SanitizerConfig{
    .sanitizeDomClobbering = true, // Enabled by default
};

// <img id="location"> → id removed (would shadow window.location)
// <form name="document"> → name removed (would shadow document)
```

### 4. URI Validation Modes

```zig
// Permissive (default)
const config1 = z.SanitizerConfig{
    .strictUriValidation = false,
};
// Allows: http:, https:, mailto:, relative paths, data:image/*

// Strict
const config2 = z.SanitizerConfig{
    .strictUriValidation = true,
};
// Allows: Only http:, https:, mailto:
// Blocks: Relative paths, data: URIs
```

### 5. Inline Style Sanitization

```zig
const config = z.SanitizerConfig{
    .sanitizeInlineStyles = true, // Enabled by default
};

// <div style="color: red"> → allowed
// <div style="expression(alert(1))"> → style removed (dangerous)
// <div style="url(javascript:...)"> → style removed (dangerous)
```

## Static Spec vs Runtime Config

The architecture ensures h5sc compliance while allowing runtime flexibility:

```zig
// This element is ALWAYS blocked (html_spec security baseline)
// Config cannot override this
const always_blocked = "<script>alert(1)</script>";

// This attribute is ALWAYS blocked (html_spec security baseline)
// Config cannot override this
const always_blocked_attr = "onclick='alert(1)'";

// Framework attributes: User decides at runtime
// html_spec marks them as safe (non-event) or unsafe (event)
// Config controls which frameworks are enabled
const x_show = "x-show='isOpen'"; // Safe if allow_alpine = true
const x_on = "x-on:click='handle()'"; // ALWAYS blocked (event handler)
```

## Integration with Parsing

### Using with Document.parseHTML

```zig
// Create a sanitizer config
const config = z.SanitizerConfig.default();
const sanitizer = try z.Sanitizer.init(allocator, config);
defer sanitizer.deinit();

// Parse HTML with sanitization
// TODO: Integration API coming soon
// const doc = try z.Document.parseHTML(allocator, html, .{
//     .sanitizer = sanitizer,
// });
```

### Using with Element.setHTML

```zig
// Web API equivalent: element.setHTML(html, { sanitizer })
// TODO: Integration API coming soon
// try element.setHTML(allocator, html, .{
//     .sanitizer = sanitizer,
// });
```

## Use Cases

### 1. Blog Comments (Strict)

```zig
const blog_sanitizer = try z.Sanitizer.initStrict(allocator);
defer blog_sanitizer.deinit();

// User-generated content: Maximum security
// Blocks: scripts, styles, frameworks, embeds
```

### 2. CMS Content (Default)

```zig
const cms_sanitizer = try z.Sanitizer.initDefault(allocator);
defer cms_sanitizer.deinit();

// Trusted editors but not developers
// Allows: Most HTML, no scripts
// Blocks: Dangerous elements, event handlers
```

### 3. Admin Panel (Permissive)

```zig
const admin_sanitizer = try z.Sanitizer.initPermissive(allocator);
defer admin_sanitizer.deinit();

// Highly trusted content
// Allows: styles, iframes, framework attributes
// Blocks: Only scripts, event handlers
```

### 4. Alpine.js App (Framework-Specific)

```zig
const alpine_config = z.SanitizerConfig{
    .frameworks = .{
        .allow_alpine = true,
        .allow_vue = false,
        .allow_htmx = false,
        .allow_phoenix = false,
    },
    .removeElements = &[_][]const u8{ "script", "iframe" },
};

const alpine_sanitizer = try z.Sanitizer.init(allocator, alpine_config);
defer alpine_sanitizer.deinit();

// Perfect for Alpine.js templates
// x-show, x-model, x-bind:* ✅
// x-on:*, v-if, hx-get ❌
```

## Performance

- **Compile-time**: `html_spec.zig` is static - O(1) lookups via hash maps
- **Runtime**: `SanitizerConfig` filters are simple array/prefix checks
- **Zero overhead**: When using `.none` mode, sanitization is completely skipped

## Migration from SanitizerOptions

The old `SanitizerOptions` still works for backward compatibility:

```zig
// Old API (still supported)
const old_opts = z.SanitizerOptions{
    .remove_scripts = true,
    .allow_framework_attrs = true,
};

// New API (Web-compatible)
const new_config = z.SanitizerConfig{
    .removeElements = &[_][]const u8{ "script" },
    .frameworks = .{}, // All enabled by default
};
```

## References

- [HTML Sanitizer API Spec](https://wicg.github.io/sanitizer-api/)
- [SanitizerConfig - MDN](https://developer.mozilla.org/en-US/docs/Web/API/SanitizerConfig)
- [Element.setHTML() - MDN](https://developer.mozilla.org/en-US/docs/Web/API/Element/setHTML)
- [DOMPurify](https://github.com/cure53/DOMPurify) - Reference implementation
- [h5sc Tests](https://html5sec.org/) - Security test suite
