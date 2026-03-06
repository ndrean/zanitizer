/**
 * zanitize.js — browser + Node.js loader for zanitize.wasm
 *
 * Usage (browser):
 *   import { loadZanitize } from './zanitize.js';
 *   const zan = await loadZanitize(new URL('./zanitize.wasm', import.meta.url));
 *   const clean = zan.sanitize('<script>bad</script><p>ok</p>');
 *
 * Usage (Node.js):
 *   import { loadZanitize } from './zanitize.js';
 *   const zan = await loadZanitize(new URL('./zanitize.wasm', import.meta.url));
 *   const clean = zan.sanitize('<b onclick="x()">hi</b>');
 *
 * WASI notes:
 *   The .wasm targets wasm32-wasi. The 8 required WASI syscalls are stubbed
 *   here — no real filesystem or process access occurs. fd_write (stdout/stderr)
 *   is silently dropped. proc_exit(0) (from _start → main) is handled by
 *   catching the ExitError thrown by the polyfill.
 */

'use strict';

const ENC = new TextEncoder();
const DEC = new TextDecoder();

class ExitError extends Error {
  constructor(code) { super(`proc_exit(${code})`); this.code = code; }
}

/**
 * Load and initialise zanitize.wasm.
 *
 * @param {URL|string} wasmUrl  Path/URL to zanitize.wasm.
 * @returns {Promise<Zanitize>} Ready-to-use sanitizer instance.
 */
export async function loadZanitize(wasmUrl) {
  // ── 1. Fetch + compile ──────────────────────────────────────────────────
  let wasmModule;
  const url = wasmUrl instanceof URL ? wasmUrl : new URL(wasmUrl);
  if (url.protocol === 'file:' || typeof process !== 'undefined') {
    // Node.js / file URL: read from disk (Node fetch doesn't support file://)
    const { readFileSync } = await import('node:fs');
    const bytes = readFileSync(url);
    wasmModule = await WebAssembly.compile(bytes);
  } else if (typeof WebAssembly.compileStreaming === 'function') {
    wasmModule = await WebAssembly.compileStreaming(fetch(String(url)));
  } else {
    wasmModule = await WebAssembly.compile(await (await fetch(String(url))).arrayBuffer());
  }

  // ── 2. Minimal WASI polyfill ────────────────────────────────────────────
  // `mem` is set after instantiate() and before _start(), so all WASI
  // functions (which are only invoked during/after _start) can safely read it.
  let mem;
  const dv = () => new DataView(mem.buffer);

  const wasi = {
    wasi_snapshot_preview1: {
      args_get:       ()                              => 0,
      args_sizes_get: (argc_ptr, buf_size_ptr)        => { dv().setUint32(argc_ptr, 0, true); dv().setUint32(buf_size_ptr, 0, true); return 0; },
      fd_write:       (_fd, iovs_ptr, iovs_len, nwritten_ptr) => {
        let total = 0;
        for (let i = 0; i < iovs_len; i++) total += dv().getUint32(iovs_ptr + i * 8 + 4, true);
        dv().setUint32(nwritten_ptr, total, true);
        return 0; // silently drop output
      },
      fd_read:        ()                              => 8,   // EBADF
      fd_seek:        ()                              => 70,  // ESPIPE
      fd_pwrite:      ()                              => 8,   // EBADF
      fd_filestat_get:()                              => 8,   // EBADF
      proc_exit:      (code)                          => { throw new ExitError(code); },
    }
  };

  // ── 3. Instantiate ──────────────────────────────────────────────────────
  const instance = await WebAssembly.instantiate(wasmModule, wasi);
  const exp = instance.exports;
  mem = exp.memory;
  // We do NOT call _start() / main():
  //   _start() → main() → proc_exit(0) throws ExitError which can corrupt
  //   wasi-libc's malloc init sequence, silently breaking subsequent alloc()
  //   calls. Our exports (init/sanitize) don't depend on C runtime startup —
  //   wasi-libc malloc self-initialises on first use via memory.grow.

  // ── 4. Public API ───────────────────────────────────────────────────────
  return new Zanitize(exp, mem);
}

class Zanitize {
  #exp; #mem;

  constructor(exports, memory) {
    this.#exp = exports;
    this.#mem = memory;
  }

  /**
   * (Re-)initialise the sanitizer with a JSON SanitizerConfig.
   * Call once (or when config changes). Omit for safe defaults.
   *
   * @param {string} [configJson]  JSON string, e.g. '{"removeElements":["script"]}'
   * @returns {boolean}  true on success.
   */
  init(configJson = '') {
    const { init, alloc, dealloc } = this.#exp;
    if (!configJson) return init(0, 0) === 1;
    const bytes = ENC.encode(configJson);
    const ptr = alloc(bytes.length);
    if (!ptr) { console.warn('zanitize: alloc() failed in init() — OOM?'); return false; }
    new Uint8Array(this.#mem.buffer, ptr, bytes.length).set(bytes);
    const ok = init(ptr, bytes.length) === 1;
    dealloc(ptr, bytes.length);
    if (!ok) console.warn('zanitize: init() returned 0 — config parse failed?', configJson);
    return ok;
  }

  /**
   * Sanitize an HTML fragment and return only the body content (no <html>/<head> wrapper).
   * This is the right method for sanitizing user-supplied snippets for insertion into a page.
   *
   * @param {string} html  Raw HTML fragment.
   * @returns {string|null}  Sanitized inner-body HTML, or null on error.
   */
  sanitizeFragment(html) {
    const full = this.sanitize(html);
    if (!full) return null;
    // Output is always <html><head>...</head><body>CONTENT</body></html>.
    // Extract just CONTENT.
    const start = full.indexOf('<body>');
    const end   = full.lastIndexOf('</body>');
    return (start !== -1 && end !== -1) ? full.slice(start + 6, end) : full;
  }

  /**
   * Sanitize an HTML string, returning a full document.
   * Use sanitizeFragment() when you only need the body content.
   *
   * @param {string|Element} html  Raw HTML string, or a DOM element (outerHTML is used).
   * @returns {string|null}  Sanitized HTML document, or null on internal error.
   */
  sanitize(html) {
    const { sanitize, result_len, free_result, alloc, dealloc } = this.#exp;
    if (typeof html !== 'string') html = html.outerHTML ?? String(html);
    const bytes = ENC.encode(html);
    const ptr = alloc(bytes.length);
    if (!ptr) return null;
    new Uint8Array(this.#mem.buffer, ptr, bytes.length).set(bytes);
    const resultPtr = sanitize(ptr, bytes.length);
    dealloc(ptr, bytes.length);
    if (!resultPtr) return null;
    const len = result_len();
    const out = DEC.decode(new Uint8Array(this.#mem.buffer, resultPtr, len));
    free_result();
    return out;
  }
}
