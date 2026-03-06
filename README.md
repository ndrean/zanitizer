# Zanitizer (`zan`)

![Zig support](https://img.shields.io/badge/Zig-0.15.2-color?logo=zig&color=%23f3ab20)

`zantizer` is a fast HTML+CSS sanitizer, heavily based on `lexbor`.

<p align="center">
<img src="https://github.com/ndrean/zexplorer/blob/zanitizer/images/GGI_zanitizer.png" alt="Gemini Generated Image" width="700" height="700" />
</p>

<br>

This tool can be used as a:

- composable, embeddable CLI (1.6MB)
- as a WASM module (700kB) (`Node` and browser).


It's a DOM-CSS level sanitizer, not a string filter. It performs the sanitization in context, meaning  DOM and CSS aware, so retains the structure.
It can allow framework attributes and uses presets or a `SanitizeConfig`.

**Speed test**:

Sanitize:

- <https://github.com/ndrean/zexplorer/blob/main/src/tests/input/dirty.html>
- <https://github.com/ndrean/zexplorer/blob/main/src/tests/input/h5sc-test.html>

| Operation            | WASM zaniter | JSDOM+DOMPurify |
| -------------------- | ---------    | --------------- |
| DOMPurify 84kB HTML  |  1.1ms       | 16ms            |
| H5SC 24kB HTML       |  10ms        | 72ms            |

```sh
node src/tests/jsdom/dompurify-jsdom-html-speed.js
node src/tests/wasm/dompurify-html-speed.js
node src/tests/jsdom/h5sc-dompurify-jsdom.js
node src/tests/wasm/h5sc-speed-test.js
```

---

## Quick start

- Using the composable CLI:

```sh
echo "<script>alert(1)</script><p>Hello</p>" \
  | ./zig-out/bin/zan - 

# => <html><head></head><body><p>Hello</p></body></html>
```

- Using the WASM module:

```sh
echo "
import('./wasm-out/zanitize.js').then(({loadZanitize}) => {
  loadZanitize(new URL('./wasm-out/zanitize.wasm', import.meta.url)).then(zan => {
    zan.init();
    const html = '<script>alert(1)</script><p>ok</p>';
    console.log(zan.sanitize(html));
  });
});" \
  | node -

# => <html><head></head><body><p>ok</p></body></html>
```

### Example: Sanitize HTML and CSS

The  `<style>` elements and inline styles are sanitzed in oe-pass.

Example: _test.html_

```html
<html>
  <head>
    <style>
      body { margin: 10px; padding: 5px; background: url(javascript:alert("xss")); }
      .trusted { color: green; }
      .untrusted {color: red; background-image: url("evil.com"); }
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

Then run:

```sh
cat test.html | ./zig-out/bin/zan -
```

This gives:

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

**Field reference**:

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

## Tests

It applies whitelist and [html_specs rules](https://github.com/ndrean/zexplorer/blob/main/src/modules/html_specs.zig) marks the node or attributes for removal or update (sanitized attributes) and processes templates separately. It then applies the collected changes once the walk completes.

There are settings for the sanitizer (remove comments, remove/keep `<script>`, `<style>`, custom elements, allow framework attributes, embedded media with attributes in context...).
Preset built-in modes are proposed but can be customized per run.

### Speed tests

Sanitize a 84kB HTML: <https://github.com/ndrean/zexplorer/blob/main/src/tests/input/dirty.html>

`node src/tests/jsdom/dompurify-jsdom-html-speed.js`: 16ms
`node src/tests/wasm/dompurify-html-speed.js`: 1.1ms

Sanitize a 24kB HTML: <https://github.com/ndrean/zexplorer/blob/main/src/tests/input/h5sc-test.html>

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

|Suite	|Cases|
|---|----|
|OWASP XSS Filter Evasion	|70|
|OWASP XSS Prevention	|6|
|OWASP DOM Clobbering	|5|
|DOMPurify-derived	|14|
|OWASP Encoding Bypasses	|23|
|PortSwigger Event Handlers	|79|
||CSS Injection Vectors	|11|
|HTML5 Security Vectors	|20|

The vector source is _tests/input/owasp_vectors.json_, extracted from _src/modules/sanitizer_test_vectors.zig_:

```sh
node tests/extract_zig_vectors.mjs   # regenerate JSON from Zig source
```

## Tips

We can use `"bypassSafety" to check how strings are parsed by Lexbor, and then evaluate the same with sanitizer 'on'.

```sh
node -e "
import('/Users/nevendrean/code/zig/zexplorer/wasm-out/zanitize.js').then(async ({loadZanitize}) => {
  const zan = await loadZanitize(new URL('file:///Users/nevendrean/code/zig/zexplorer/wasm-out/zanitize.wasm'));
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

[SECURITY.md](https://github.com/ndrean/zexplorer/blob/main/SECURITY.md)

## Reporting Vulnerabilities

If you discover a sanitizer bypass, please report it responsibly. Open an issue or contact the maintainers directly. Include:

1. The input HTML/CSS payload
2. The sanitizer mode and options used
3. What dangerous content survives sanitization

## Licenses

This software uses heavily [lexbor](https://lexbor.com)

- `lexbor` [License Apache 2.0](https://github.com/lexbor/lexbor/blob/master/LICENSE)
- `md4c` [License MIT](https://github.com/mity/md4c/blob/master/LICENSE.md)

## Using Markdown input

We use the library [md4c](https://github.com/mity/md4c).

> Usage: just add the flag `--md`.

An example:

```sh
echo "# Hello from Markdown

This is **GFM** rendered natively via md4c.

| Column A | Column B |
|----------|----------|
| foo      | bar      |
| baz      | qux      |

- [x] md4c parses GFM Markdown
- [x] lexbor renders the resulting HTML
- [ ] profit

~~Strikethrough~~, https://example.com autolink, and <span style="color:red">raw HTML</span> all pass through." \
| ./zig-out/bin/zan - --md
```

gives:

```html
<html>
  <head></head>
  <body>
    <h1>Hello from Markdown</h1>
    <p>This is <strong>GFM</strong> rendered natively via md4c.</p>
    <p>
      | Column A | Column B |
      |----------|----------|
      | foo      | bar      |
      | baz      | qux      |
    </p>
    <ul>
      <li>[x] md4c parses GFM Markdown</li>
      <li>[x] lexbor renders the resulting HTML</li>
      <li>[ ] profit</li>
    </ul>
    <p>
      ~~Strikethrough~~, https://example.com autolink, and <span style="color: red">raw HTML</span> all pass through.
    </p>
  </body>
</html>
```

---

## Notes

**Update lexbor**:

```sh
git submodule update --remote vendor/lexbor_src_master
```

**Leaks**: lexbor + Zig

```sh
MallocStackLogging=1 leaks -atExit -- cat dirty.html | ./zig-out/bin/zan -
```

**search in `lexbor` built static**: to check if primitives are exported, you can use:

```sh
nm vendor/lexbor_src_master/build/liblexbor_static.a | grep " T " | grep -i "serialize"
```

Directly in the source code:

```sh
find vendor/lexbor_src_master/source -name "*.h" | xargs grep -l "lxb_html_seralize_tree_cb"

grep -r "lxb_html_serialize_tree_cb" vendor/lexbor_src_master/source/lexbor/
```