# Security Policy

## Overview

Zanitize's HTML/CSS sanitizer provides defense-in-depth against XSS, mXSS, CSS injection, DOM clobbering, and protocol-based attacks. It operates structurally on the parsed DOM and CSS AST — not with regex or string replacement — making it resistant to parser differentials and encoding tricks.

The architecture follows a **parse → annotate → batch-remove** pattern: the document is parsed into a full DOM tree (via Lexbor), walked once to collect dangerous nodes and attributes, then all removals are applied in reverse order in a second pass. This avoids iterator corruption and use-after-free issues that plague in-place removal approaches.

## Sanitization Strategy at a Glance

### Sanitization model

The sanitizer operates on the **live Lexbor DOM and CSS AST** — there is no serialize/re-parse step, so there is no parse-differential surface for mXSS. HTML character references are decoded by Lexbor at parse time, before the sanitizer sees any attribute value.

The pipeline:

```txt
Raw HTML / SVG / CSS
        │
        ▼
  Lexbor parse ── entities decoded, DOM + CSSOM built
        │
        ├─── DOM node tree ──────────────────────┐
        │    walk every node                     │
        │    • remove dangerous elements         │
        │    • strip unsafe attributes           │    merge sanitized
        │    • inline style → CSS sanitizer      │    CSS back into DOM
        │                                        │
        └─── CSS AST (stylesheets + style="")  ──┘
             • remove dangerous at-rules
             • strip unsafe properties
             • validate URIs structurally

        ▼
  Sanitized DOM — safe for rendering or serialization
```

**Policy decisions and known trade-offs:**

| Threat | Policy | Rationale | Gap / known trade-off |
| --- | --- | --- | --- |
| `<script>` tags | Removed by default; configurable via `remove_scripts: bool` | Removed at parse time before any execution can occur | — |
| `on*` event handlers | Always removed | No legitimate use in sanitized output | — |
| `href="javascript:"`, `vbscript:`, `file:` | Blocked on all URL attributes (`href`, `src`, `action`, `poster`, `data`, …) | These protocols execute code or access local files | — |
| `data:` URIs — non-image | Blocked entirely | `data:text/html`, `data:text/javascript` are direct XSS vectors | — |
| `data:image/svg+xml` | Blocked | SVG images can contain `<script>` and event handlers | — |
| `data:image/*` — other | Allowed only with `;base64` encoding **and** matching magic bytes | Non-base64 binary images are never legitimate; magic byte check (PNG/JPEG/WebP/GIF header) blocks mislabeled or polyglot payloads | `image/avif`, `image/bmp`, etc. have no magic checker — pass through on MIME type alone |
| External image `src` (`https://…`) | Allowed | External images are legitimate content; blocking would break most pages | Tracking pixels are a known consequence — this is a content policy decision, not a sanitizer decision |
| `srcset` attribute | Allowed without URL validation | `srcset` contains multiple space-separated URLs; browsers do not execute JavaScript from `srcset` | Known gap: a `javascript:` URL in `srcset` would pass through (browsers ignore it, but the string survives) |
| `//evil.com` protocol-relative | Allowed | Protocol-relative URLs are legitimate for same-protocol assets | In HTTP contexts, loads HTTP even on an HTTPS page; caller should enforce CSP |
| `<style>` blocks | CSS AST sanitized — dangerous at-rules (`@import`, `@namespace`) removed, unsafe properties stripped | Tokenized AST parsing: obfuscated `expression()` and `url(javascript:)` are structurally detected, not regex-matched | — |
| Inline `style=""` | CSS sanitizer applied per-attribute | `background-image: url(evil.com)` is an exfiltration vector — stripped | — |
| SVG `<foreignObject>`, `<feImage>`, `<animate>`, `<animateMotion>`, `<set>`, `<switch>` | Blocked | `foreignObject` re-enters HTML parsing context (primary mXSS entry point); `feImage` loads external resources; animate* can trigger event handlers | — |
| SVG `href` / `xlink:href` | Fragment-only (`#id`) for most elements; `<image>` and `<a>` use standard URI validation | External SVG resources via `<use href="external.svg#x">` load arbitrary SVG | — |
| MathML | Allowed in correct context with attribute allowlist; `href`, `xlink:href`, `on*` removed | Prevents XSS via invalid MathML nesting or href abuse | — |
| DOM clobbering (`id`, `name`) | Values that shadow `window`/`document` properties filtered | Prevents `id="cookie"` from overriding `document.cookie` etc. | — |
| mXSS / obfuscated encoding | Entity decoding happens at Lexbor parse time; `containsMxssPattern` run on all attribute values; CSS content AST-sanitized | No serialize/re-parse step means no parse-differential surface | Text nodes inside SVG `<title>`, `<desc>`, `<text>` are not pattern-checked — low risk because `foreignObject` (the main SVG escape hatch) is blocked |
| `<iframe>` | Allowed only with `sandbox` attribute; `src` and `srcdoc` validated | Prevents loading of arbitrary external content | `allow-scripts` in `sandbox` is blocked; other dangerous combinations not exhaustively validated |
| Framework attributes (`v-html`, `ng-bind-html`, `x-html`, `:innerHTML`) | Removed by default; configurable via `frameworks: FrameworkConfig` | These attributes trigger HTML injection in their respective runtimes | When allowed, values are checked against `DANGEROUS_JS_PATTERNS` but not fully sanitized |
| CSP generation | Not provided | CSP is a server/browser responsibility, not a DOM sanitizer responsibility | Caller must set appropriate `Content-Security-Policy` headers when serving sanitized output |

---

### Elements

| Category | Strategy | Action | Examples |
| --- | --- | --- | --- |
| Known HTML elements | **allowlist** | keep | `<div>`, `<p>`, `<table>`, `<form>`, `<details>`, `<search>`, ... |
| `<script>` | **blocklist** | remove (configurable) | `<script>alert(1)</script>` |
| `<style>` | **blocklist** or **sanitize** | remove or sanitize CSS content | `<style>body{color:red}</style>` |
| `<iframe>`, `<embed>`, `<object>` | **blocklist** | remove (configurable) | `<iframe src="...">` |
| `<template>` | **recurse** | sanitize fragment content separately | `<template><img onerror=...></template>` |
| Custom elements (with `-`) | **configurable** | allow or remove | `<my-widget>`, `<x-component>` |
| Unknown elements | **blocklist** | remove | `<blink>`, `<xss>` |
| SVG elements | **allowlist** | keep ~50 safe elements | `<svg>`, `<rect>`, `<path>`, `<text>`, `<filter>`, ... |
| SVG dangerous | **blocklist** | remove | `<script>`, `<foreignObject>`, `<animate>`, `<set>` |
| MathML elements | **allowlist** | keep safe notation elements | `<math>`, `<mi>`, `<mo>`, `<mrow>`, `<mfrac>`, ... |
| MathML dangerous | **blocklist** | remove | `<maction>`, `<annotation-xml>`, `<semantics>` |
| Comments | **configurable** | remove (default) | `<!-- comment -->` |

### Attributes

| Category | Strategy | Action | Examples |
| --- | --- | --- | --- |
| Event handlers (`on*`) | **pattern remove** | always remove (any `on` + alpha) | `onclick`, `onerror`, `onanimationend`, ... (all 72+ variants) |
| Named dangerous attrs | **blocklist** | always remove | `innerHTML`, `outerHTML`, `formaction`, `background`, `autofocus`, `integrity` |
| Framework HTML injection | **blocklist** | always remove | `x-html`, `v-html`, `ng-bind-html` |
| Per-element known attrs | **allowlist** | keep if in element spec | `href` on `<a>`, `src` on `<img>`, `type` on `<input>` |
| Enum-validated attrs | **allowlist + enum** | keep if value matches | `type="text"`, `dir="ltr"`, `target="_blank"` |
| URI-bearing attrs | **allowlist + validate** | keep if URI is safe | `href`, `src`, `action`, `poster`, `data` |
| `style` attribute | **allowlist + sanitize** | keep with sanitized CSS value | `style="color: red"` |
| `aria-*` prefix | **prefix allow** | always keep | `aria-label`, `aria-hidden`, `aria-describedby` |
| `data-*` prefix | **prefix allow** | always keep | `data-id`, `data-value`, `data-custom` |
| `id`, `name` | **allowlist + clobber check** | keep unless DOM-clobbering name | `id="myEl"` kept, `id="location"` removed |
| OWASP safe presentational | **allowlist** (global) | always keep (deprecated but harmless) | `align`, `bgcolor`, `border`, `color`, `valign`, `nowrap` |
| OWASP safe presentational | **allowlist** (element-specific) | keep on applicable elements | `cellpadding`, `cellspacing`, `scrolling`, `hspace`, `vspace`, ... |
| Framework attrs | **configurable prefix allow** | keep with JS value scanning | `hx-get`, `v-if`, `x-show`, `phx-hook` |
| Framework event attrs | **blocklist** | remove | `hx-on:*`, `v-on:*`, `@click`, `on:*` |
| SVG `href`/`xlink:href` | **fragment-only validate** | keep only `#id` references | `xlink:href="#icon"` kept, `xlink:href="http://..."` removed |
| Unknown attributes | **allowlist principle** | remove | any attr not in element spec |
| Cross-attr dependencies | **dependency check** | remove if dep missing | `target="_blank"` requires `rel="noopener"` |

### Attribute Values — mXSS Detection

| Pattern | Threat | Action |
| --- | --- | --- |
| `</style>`, `</script>`, `</title>`, ... | Tag breakout on re-parse | remove attribute |
| `]]>`, `-->`, `--!>` | CDATA/comment breakout | remove attribute |
| `xmlns=`, `xmlns:` | Namespace injection | remove attribute |
| `<![`, `<!-`, `<%`, `%>` | HTML5 parsing quirks | remove attribute |

### URIs

| Category | Strategy | Action | Examples |
| --- | --- | --- | --- |
| `javascript:` | **blocked protocol** | remove attribute | `href="javascript:alert(1)"` |
| `vbscript:` | **blocked protocol** | remove attribute | `href="vbscript:MsgBox"` |
| `file:` | **blocked protocol** | remove attribute | `src="file:///etc/passwd"` |
| `data:text/html` | **blocked data URI** | remove attribute | `src="data:text/html,<script>..."` |
| `data:text/javascript` | **blocked data URI** | remove attribute | `href="data:text/javascript,alert(1)"` |
| `data:image/svg+xml` | **blocked data URI** | remove attribute | `src="data:image/svg+xml,<svg onload=...>"` |
| `data:image/*` (non-SVG) | **allowed data URI** | keep | `src="data:image/png;base64,..."` |
| `http://`, `https://` | **allowed protocol** | keep | `href="https://example.com"` |
| Protocol-relative `//` | **strict mode only** | remove in strict mode | `src="//evil.com/payload.js"` |
| Path traversal `../` | **strict mode only** | remove in strict mode | `src="../../../etc/passwd"` |
| Encoding bypasses | **normalize first** | decode entities, strip control chars, trim unicode whitespace | `&#106;avascript:`, `\t\njavascript:` |

### CSS

| Category | Strategy | Action | Examples |
| --- | --- | --- | --- |
| `@import` | **blocked at-rule** | always remove | `@import url("evil.css")` |
| `@charset` | **blocked at-rule** | always remove | `@charset "UTF-7"` |
| `@namespace` | **blocked at-rule** | always remove | `@namespace svg url(...)` |
| `@keyframes`, `@media`, `@font-face` | **configurable** | keep by default | `@media (max-width: 600px) {...}` |
| `behavior` | **blocked property** | always remove | `behavior: url(xss.htc)` |
| `-moz-binding` | **blocked property** | always remove | `-moz-binding: url("xbl")` |
| `-webkit-user-modify` | **blocked property** | always remove | `-webkit-user-modify: read-write` |
| `-o-link`, `-o-link-source` | **blocked property** | always remove | `-o-link: javascript:alert(1)` |
| `filter` (with `progid:`) | **blocked property** | always remove | `filter: progid:DXImageTransform...` |
| Safe properties | **allowlist** | keep (~90 standard properties) | `color`, `margin`, `display`, `flex`, `grid`, ... |
| `expression()` | **blocked function** | always remove | `width: expression(alert(1))` |
| `eval()` | **blocked function** | always remove | `top: eval(...)` |
| `progid:` | **blocked function** | always remove | legacy IE filters |
| `-webkit-calc()` | **blocked function** | always remove | vendor prefix bypass |
| `url()` | **validate content** | keep if URI is safe | `url(https://...)` kept, `url(javascript:...)` removed |
| `calc()` | **configurable function** | allowed by default | `width: calc(100% - 20px)` |
| `var()` | **configurable function** | blocked by default (data exfil risk) | `color: var(--secret)` |
| `env()` | **configurable function** | blocked by default | `padding: env(safe-area-inset-top)` |
| Standard functions | **allowlist** (~50 functions) | always keep | `rgb()`, `hsl()`, `linear-gradient()`, `rotate()`, `clamp()`, ... |
| Unknown functions | **blocked** (default ruleset) | remove | any function not in ruleset |
| String literal content | **skip** (structural parsing) | safe — never executes | `content: "expression() is not code"` |

## Sanitization Modes

| Preset | Scripts | Styles | Comments | data-* | Custom elements | Strict URIs | DOM clobbering |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **default** | removed | sanitized | stripped | kept | allowed | no | protected |
| **strict** | removed | sanitized | stripped | stripped | blocked | yes | protected |
| **permissive** | removed | sanitized | kept | kept | allowed | no | protected |
| **trusted** ⚠️ | kept | kept | kept | kept | allowed | no | off |

The public `SanitizeOptions` struct (use `.{}` for safe defaults):

```zig
pub const SanitizeOptions = struct {
    remove_scripts: bool = true,       // remove <script> tags
    remove_styles: bool = false,       // false = sanitize CSS instead of stripping
    sanitize_css: bool = true,         // sanitize inline styles + <style> content
    remove_comments: bool = true,      // strip HTML comments
    strict_uri: bool = false,          // block relative paths and data: URIs
    sanitize_dom_clobbering: bool = true,
    allow_custom_elements: bool = true,
    allow_embeds: bool = false,
    allow_iframes: bool = false,
    frameworks: FrameworkConfig = .{}, // per-framework attribute config
    bypass_safety: bool = false,       // ⚠️ DANGER: only for trusted content
    // WHATWG SanitizerConfig element/attribute filters:
    elements: ?[]const ElementConfig = null,
    remove_elements: ?[]const []const u8 = null,
    replace_with_children: ?[]const []const u8 = null,
    allowed_attributes: ?[]const []const u8 = null,
    remove_attributes: ?[]const []const u8 = null,
};
```

## Architecture: Parse → Annotate → Batch Remove

### Phase 1: DOM Walk (Collection)

A single depth-first walk visits every node. For each element, a multi-layer validation pipeline runs:

```txt
Node
 ├─ Comment → remove if skip_comments
 ├─ Text → always safe (already parsed, no re-interpretation)
 └─ Element
     ├─ Template → recurse into fragment content separately
     ├─ Script → remove if remove_scripts
     ├─ Style → remove OR sanitize CSS content
     ├─ SVG context → SVG allowlist + attribute filter
     ├─ MathML context → MathML allowlist
     ├─ Known element → validate attributes (see below)
     └─ Unknown element
         ├─ Custom element (has hyphen, e.g. <my-widget>) → allow if configured
         └─ Otherwise → remove
```

Dangerous nodes and attributes are **collected into lists** — never removed during the walk.

### Phase 2: Post-Walk (Batch Removal)

After the walk completes:

1. **Remove attributes** flagged as dangerous
2. **Update attributes** with sanitized values (e.g. cleaned inline styles)
3. **Recurse into `<template>` fragments** (separate document fragments with their own walk)
4. **Remove nodes in reverse discovery order** — children are removed before their parents, preventing double-free

A single arena allocator backs all temporary strings and lists, deallocated in one call at the end.

## Attribute Validation Pipeline

Each attribute passes through up to five layers:

### Layer 1: Blocklist (immediate removal)

`DANGEROUS_ATTRIBUTES` is a `StaticStringMap` with O(1) lookup, plus a **generic `on*` pattern catch** for any event handler not explicitly listed:

- **Named event handlers**: `onclick`, `onload`, `onerror`, `onfocus`, `onblur`, `onchange`, `onsubmit`, `onkeydown`, `onkeyup`, `onmouseover`, `onmouseenter`, `onmouseleave`, `onresize`, `onmessage`, `onstorage`, `onunload`, `onbeforeunload`, `onhashchange`
- **Generic `on*` pattern**: any attribute starting with `on` followed by an alphabetic character is removed — catches all 72+ event handler variants without needing to enumerate them
- **HTML injection**: `innerHTML`, `outerHTML` — framework binding attributes that trigger innerHTML injection (e.g. `[innerHTML]="expr"` in Angular, `<div innerHTML="...">` in some SSR renderers)
- **Framework HTML injection**: `x-html`, `v-html`, `ng-bind-html`
- **Legacy/dangerous**: `formaction`, `background`, `autofocus`, `integrity`

### Layer 2: mXSS Pattern Detection

Attribute values are checked for mutation XSS patterns — strings that, when re-parsed by the browser, change meaning:

- Tag breakouts: `</style>`, `</script>`, `</title>`, `</textarea>`, `</noscript>`
- CDATA/comment closers: `]]>`, `-->`, `--!>`
- Namespace injection: `xmlns=`, `xmlns:`
- HTML5 quirks: `<![`, `<!-`, `<%`, `%>`

### Layer 3: Runtime Configuration

- **Inline styles**: sanitized via CSS sanitizer or removed based on config
- **DOM clobbering**: `id` and `name` attributes checked against `DOM_CLOBBERING_NAMES`
- **Framework attributes**: allowed/blocked per framework config, with JS pattern scanning on values

### Layer 4: Per-Element Attribute Spec (Allowlist)

Each HTML element has a spec defining its allowed attributes and valid values:

- **Enum validation**: attributes like `type`, `rel`, `target` are checked against a list of valid values
- **URI validation**: `href`, `src`, `action` pass through `validateUri`
- **SVG URI validation**: `xlink:href` allows fragment-only references (`#icon`)
- **Unknown attributes are removed** (allowlist principle)

### Layer 5: Cross-Attribute Dependencies

- `target="_blank"` requires `rel` containing `noopener` or `noreferrer`
- Missing dependency → attribute removed

## URI Validation

URIs in `href`, `src`, `action`, `poster`, `data`, `background` attributes are normalized and validated:

1. **HTML entity decoding** (prevents `&#106;avascript:` bypasses)
2. **Unicode whitespace trimming** (prevents `\u200E javascript:` bypasses)
3. **Control character stripping** (prevents tab/newline injection in protocols)

**Blocked protocols**: `javascript:`, `vbscript:`, `file:`

**Blocked data URIs**: `data:text/html`, `data:text/javascript`, `data:text/xml`, `data:application/xhtml`, `data:image/svg+xml`

**Allowed data URIs**: `data:image/*` (except SVG) — images only

**Strict mode additionally blocks**: protocol-relative URLs (`//evil.com`), path traversal (`../`)

## CSS Sanitization

CSS is sanitized structurally, not with pattern matching. Two paths exist:

### Lexbor AST Path (primary)

CSS is parsed into a Lexbor AST. Each rule is walked:

1. **At-rules**: `@import`, `@charset`, `@namespace` are always removed (external resource loading / encoding attacks). `@keyframes`, `@media`, `@font-face` are configurable.
2. **Properties**: checked against `SAFE_CSS_PROPERTIES` allowlist (whitelist approach) or `DANGEROUS_CSS_PROPERTIES` blocklist. Dangerous properties: `behavior`, `-moz-binding`, `-webkit-user-modify`, `-o-link`, `-o-link-source`, `filter` (with `progid:`).
3. **Values**: validated by the `CssValueScanner`.

### CssValueScanner: Structural Value Analysis

The scanner is a **compile-time generic** parameterized by a `CssFunctionRuleset`:

```zig
const Scanner = CssValueScanner(specs.DEFAULT_RULESET);
```

It uses a two-state machine (NORMAL / IN_STRING) to distinguish:

- **Function calls** in normal context → classified and validated
- **String literal content** → skipped entirely (safe, cannot execute)

This prevents false positives like `content: "expression() is not code"` while still catching `width: expression(alert(1))`.

### Function Classification (Compile-Time Configurable)

Each CSS function is classified at compile time:

| Class               | Examples                                                              | Behavior                                    |
| ------------------- | --------------------------------------------------------------------- | ------------------------------------------- |
| `blocked`           | `expression`, `eval`, `progid`, `-webkit-calc`                        | Always removed                              |
| `url_validate`      | `url`                                                                 | Content validated (protocol checks)         |
| `configurable_calc` | `calc`                                                                | Allowed by default, toggleable at runtime   |
| `configurable_var`  | `var`                                                                 | Blocked by default (data exfiltration risk) |
| `configurable_env`  | `env`                                                                 | Blocked by default                          |
| `allowed`           | `rgb`, `hsl`, `linear-gradient`, `rotate`, `clamp`, `min`, `max`, ... | Always allowed                              |

**Unknown functions are blocked** (allowlist principle in `DEFAULT_RULESET`).

Three built-in rulesets are provided:

- **`DEFAULT_RULESET`**: allowlist approach with ~50 standard CSS functions. Unknown → blocked.
- **`STRICT_RULESET`**: minimal function set, maximum security.
- **`PERMISSIVE_RULESET`**: blocklist approach. Unknown → allowed. Only `expression`/`eval`/`progid` blocked.

Custom rulesets can be defined at compile time:

```zig
const my_ruleset = specs.CssFunctionRuleset{
    .functions = &.{
        .{ "expression", .blocked },
        .{ "url", .url_validate },
        .{ "calc", .allowed },
        .{ "var", .allowed },
        .{ "rgb", .allowed },
    },
    .unknown_function_policy = .blocked,
};
```

## SVG Sanitization

SVG elements use a **dual allowlist/blocklist** approach:

**Allowed elements** (allowlist, ~50 elements): shapes (`rect`, `circle`, `path`, `polygon`...), text (`text`, `tspan`), gradients, filters (`feGaussianBlur`, `feBlend`...), clipping/masking, containers (`g`, `defs`, `symbol`).

**Blocked elements**: `script`, `animate`, `animateMotion`, `animateTransform`, `set`, `foreignObject` (arbitrary HTML embedding), `feImage` (external resource loading), `switch`, `view`.

**SVG attribute handling**:

- Event handlers (`on*`) → always removed
- `href` / `xlink:href` → **fragment-only** validation (only `#id` references allowed, no external URLs)
- Unknown attributes → removed (allowlist)

## DOM Clobbering Protection

When `sanitize_dom_clobbering` is enabled, `id` and `name` attributes are checked against a blocklist of names that shadow browser globals:

- **Window/Document**: `location`, `document`, `window`, `self`, `top`, `parent`, `frames`, `history`, `navigator`, `screen`, `event`
- **Dangerous properties**: `eval`, `execScript`, `Function`, `Object`, `Array`, `__proto__`, `constructor`
- **HTML elements**: `form`, `iframe`, `image`, `embed`, `object`, `body`, `head`, `style`, `script`
- **Navigation**: `alert`, `confirm`, `prompt`, `open`

Example: `<img id="location">` is sanitized because it shadows `window.location`.

## Framework Attribute Support

When `frameworks: FrameworkConfig` is configured, framework-specific attributes are preserved with safety checks:

| Framework        | Allowed Prefixes  | Blocked (Event Handlers)                |
| ---------------- | ----------------- | --------------------------------------- |
| HTMX             | `hx-*`            | `hx-on:*`                               |
| Alpine.js        | `x-*`             | `x-on:*`                                |
| Vue.js           | `v-*`, `:*`       | `v-on:*`, `@*`                          |
| Phoenix LiveView | `phx-*`           | `phx-click`, `phx-submit`, `phx-change` |
| Angular          | `*ng*`, `[*]`     | `(*)`                                   |
| Svelte           | `bind:*`, `use:*` | `on:*`                                  |

Framework attribute **values** are additionally scanned for dangerous JS patterns: `eval(`, `import(`, `fetch(`, `javascript:`, `${`, `=>`, `document.write`, `__proto__`, etc.

## mXSS (Mutation XSS) Resistance

Parser differential attacks exploit differences between the sanitizer's parser and the browser's parser. Defenses:

1. **Lexbor HTML parser** — same HTML5 spec-compliant parser used for both sanitization and rendering
2. **mXSS pattern detection** in attribute values and CSS
3. **Template content isolation** — `<template>` fragments are sanitized separately
4. **No innerHTML re-serialization for security decisions** — the sanitizer works on the DOM tree, not on re-serialized HTML strings

## Test Coverage

The sanitizer is validated against **228 OWASP/PortSwigger vectors + 138 Zig unit tests**:

| Source                                                                                                                  | Vectors | Coverage                                                             |
| ----------------------------------------------------------------------------------------------------------------------- | ------- | -------------------------------------------------------------------- |
| [OWASP XSS Filter Evasion](https://cheatsheetseries.owasp.org/cheatsheets/XSS_Filter_Evasion_Cheat_Sheet.html)          | 70      | Script injection, encoding bypasses, event handlers, protocol tricks |
| [OWASP XSS Prevention](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html) | 6       | Context-specific injection patterns                                  |
| [OWASP DOM Clobbering](https://cheatsheetseries.owasp.org/cheatsheets/DOM_Clobbering_Prevention_Cheat_Sheet.html)       | 5       | Property shadowing attacks                                           |
| [DOMPurify test suite](https://github.com/cure53/DOMPurify)                                                             | 14      | Real-world bypass patterns                                           |
| OWASP Encoding Bypasses                                                                                                 | 23      | Entity encoding, unicode tricks, protocol obfuscation                |
| [PortSwigger XSS Cheat Sheet](https://portswigger.net/web-security/cross-site-scripting/cheat-sheet)                    | 79      | Comprehensive event handler coverage (72 `on*` variants)             |
| CSS Injection Vectors                                                                                                   | 11      | `expression()`, `url()` protocols, `@import`, dangerous properties   |
| [OWASP HTML5 Security](https://cheatsheetseries.owasp.org/cheatsheets/HTML5_Security_Cheat_Sheet.html)                  | 20      | SVG/MathML, `data:` URIs, template injection, HTML5 APIs             |

Tests fail hard — any unhandled vector is a test failure:

```sh
zig build test -- --test-filter "sanitizer vector"
```

## Reporting Vulnerabilities

If you discover a sanitizer bypass, please report it responsibly. Open an issue or contact the maintainers directly. Include:

1. The input HTML/CSS payload
2. The sanitizer mode and options used
3. What dangerous content survives sanitization
