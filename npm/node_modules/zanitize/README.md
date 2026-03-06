# zanitize

Fast HTML + CSS sanitizer compiled to WebAssembly from [Zig + Lexbor](https://github.com/ndrean/zexplorer).

- **~700 kB** WASM binary
- DOM-aware — parses with a real HTML engine (Lexbor), not regexes
- Sanitizes `<style>` elements and inline `style=""` in one pass
- Works in **Node.js** and the **browser** (no WASI runtime needed)
- 10–15× faster than JSDOM + DOMPurify

## Install

```sh
npm install zanitize
```

## Usage

### Node.js

```js
import { loadZanitize } from 'zanitize';

const zan = await loadZanitize(
  new URL('./node_modules/zanitize/zanitize.wasm', import.meta.url)
);
zan.init(); // default config

console.log(zan.sanitizeFragment('<script>alert(1)</script><p>ok</p>'));
// => <p>ok</p>

console.log(zan.sanitize('<b onclick="bad()">hi</b>'));
// => <html><head></head><body><b>hi</b></body></html>
```

### Browser (Vite / webpack)

```js
import { loadZanitize } from 'zanitize';
import wasmUrl from 'zanitize/zanitize.wasm?url'; // Vite

const zan = await loadZanitize(wasmUrl);
zan.init();
div.innerHTML = zan.sanitizeFragment(untrustedHtml);
```

## API

### `loadZanitize(wasmUrl)`

Loads and compiles the WASM module. Call once at startup.

```ts
loadZanitize(wasmUrl: URL | string): Promise<ZanitizeInstance>
```

### `zan.init(configJson?)`

Initialises the sanitizer. Call before the first `sanitize()`. Safe to call again to reconfigure.

```ts
init(configJson?: string): boolean
```

```js
zan.init();                                          // safe defaults
zan.init('{"strictUriValidation": true}');           // strict URIs
zan.init(JSON.stringify({ removeElements: ['b'] })); // custom
```

### `zan.sanitizeFragment(html)`

Sanitizes an HTML fragment. Returns the `<body>` content only — ready for `innerHTML`.

```ts
sanitizeFragment(html: string): string | null
```

### `zan.sanitize(html)`

Sanitizes a full HTML string. Returns a complete `<html>…</html>` document.

```ts
sanitize(html: string): string | null
```

## SanitizerConfig

Pass a JSON string to `init()`. Fields follow the [W3C Sanitizer API](https://wicg.github.io/sanitizer-api/):

```js
zan.init(JSON.stringify({
  removeElements: ['script', 'iframe', 'object'],  // drop element + content
  replaceWithChildrenElements: ['b', 'i'],          // unwrap, keep children
  removeAttributes: ['onclick', 'onerror'],         // strip attributes
  comments: false,
  sanitizeDomClobbering: true,                      // protect window.* names
  sanitizeInlineStyles: true,                       // sanitize style=""
  strictUriValidation: false,                       // allow relative URLs
}));
```

See the [full config reference](https://github.com/ndrean/zexplorer#sanitizerconfig) for all fields and presets.

## License

MIT — uses [Lexbor](https://github.com/lexbor/lexbor) (Apache 2.0) and [md4c](https://github.com/mity/md4c) (MIT).
