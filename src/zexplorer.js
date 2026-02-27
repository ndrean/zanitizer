// --- zexplorer.js ---
// Core ZXP engine API — embedded in Zig, runs on every ScriptEngine init.
// Compat shims and environment polyfills live in polyfills.js (loaded after).

// ── Location Polyfill ──────────────────────────────────────────────────────
// Called from zxp.goto() to set window.location before user scripts run.

console.log("[zxp] Booting standard library...");

function applyLocationPolyfill(urlStr) {
  try {
    const parsedUrl = new URL(urlStr);
    const locationPolyfill = {
      href: parsedUrl.href,
      protocol: parsedUrl.protocol,
      host: parsedUrl.host,
      hostname: parsedUrl.hostname,
      port: parsedUrl.port,
      pathname: parsedUrl.pathname,
      search: parsedUrl.search,
      hash: parsedUrl.hash,
      origin: parsedUrl.origin,
      assign: (newUrl) => console.log(`[Router] Navigation ignored: ${newUrl}`),
      replace: (newUrl) => console.log(`[Router] Replace ignored: ${newUrl}`),
      reload: () => console.log("[Router] Reload ignored"),
      toString: () => parsedUrl.href,
      ancestorOrigins: [],
    };

    globalThis.location = locationPolyfill;

    globalThis.window = globalThis.window || globalThis;
    globalThis.window.location = locationPolyfill;

    if (globalThis.document) {
      Object.defineProperty(Object.getPrototypeOf(document), "location", {
        get: () => locationPolyfill,
        configurable: true,
      });
    }
  } catch (e) {
    console.error("Invalid URL for polyfill:", urlStr);
  }
}

// ── htm: JSX-like tagged templates for real DOM (no VDOM) ─────────────────
// htm parser (https://github.com/developit/htm)

var __htm_build = function (a, o, l, n) {
    var i;
    o[0] = 0;
    for (var t = 1; t < o.length; t++) {
      var e = o[t++],
        u = o[t] ? ((o[0] |= e ? 1 : 2), l[o[t++]]) : o[++t];
      e === 3
        ? (n[0] = u)
        : e === 4
          ? (n[1] = Object.assign(n[1] || {}, u))
          : e === 5
            ? ((n[1] = n[1] || {})[o[++t]] = u)
            : e === 6
              ? (n[1][o[++t]] += u + "")
              : e
                ? ((i = a.apply(u, __htm_build(a, u, l, ["", null]))),
                  n.push(i),
                  u[0] ? (o[0] |= 2) : ((o[t - 2] = 0), (o[t] = i)))
                : n.push(u);
    }
    return n;
  },
  __htm_cache = new Map();

function __htm_tag(a) {
  var o = __htm_cache.get(this);
  return (
    o || ((o = new Map()), __htm_cache.set(this, o)),
    (o = __htm_build(
      this,
      o.get(a) ||
        (o.set(
          a,
          (o = (function (l) {
            for (
              var n,
                i,
                t = 1,
                e = "",
                u = "",
                s = [0],
                b = function (f) {
                  (t === 1 && (f || (e = e.replace(/^\s*\n\s*|\s*\n\s*$/g, "")))
                    ? s.push(0, f, e)
                    : t === 3 && (f || e)
                      ? (s.push(3, f, e), (t = 2))
                      : t === 2 && e === "..." && f
                        ? s.push(4, f, 0)
                        : t === 2 && e && !f
                          ? s.push(5, 0, !0, e)
                          : t >= 5 &&
                            ((e || (!f && t === 5)) &&
                              (s.push(t, 0, e, i), (t = 6)),
                            f && (s.push(t, f, 0, i), (t = 6))),
                    (e = ""));
                },
                c = 0;
              c < l.length;
              c++
            ) {
              c && (t === 1 && b(), b(c));
              for (var g = 0; g < l[c].length; g++)
                ((n = l[c][g]),
                  t === 1
                    ? n === "<"
                      ? (b(), (s = [s]), (t = 3))
                      : (e += n)
                    : t === 4
                      ? e === "--" && n === ">"
                        ? ((t = 1), (e = ""))
                        : (e = n + e[0])
                      : u
                        ? n === u
                          ? (u = "")
                          : (e += n)
                        : n === '"' || n === "'"
                          ? (u = n)
                          : n === ">"
                            ? (b(), (t = 1))
                            : t &&
                              (n === "="
                                ? ((t = 5), (i = e), (e = ""))
                                : n === "/" && (t < 5 || l[c][g + 1] === ">")
                                  ? (b(),
                                    t === 3 && (s = s[0]),
                                    (t = s),
                                    (s = s[0]).push(2, 0, t),
                                    (t = 0))
                                  : n === " " ||
                                      n === "\t" ||
                                      n === "\n" ||
                                      n === "\r"
                                    ? (b(), (t = 2))
                                    : (e += n)),
                  t === 3 && e === "!--" && ((t = 4), (s = s[0])));
            }
            return (b(), s);
          })(a)),
        ),
        o),
      arguments,
      [],
    )).length > 1
      ? o
      : o[0]
  );
}

// h() creates real Lexbor DOM elements
function __zxp_h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (k === "style" && typeof v === "object") {
        const css = Object.entries(v)
          .map(([p, val]) => {
            const kebab = p.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase());
            return `${kebab}:${val}`;
          })
          .join(";");
        el.setAttribute("style", css);
      } else {
        el.setAttribute(k, v);
      }
    }
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    if (typeof child === "string" || typeof child === "number") {
      el.appendChild(document.createTextNode(String(child)));
    } else if (child instanceof Node) {
      el.appendChild(child);
    }
  }
  return el;
}

// ── zxp API ───────────────────────────────────────────────────────────────

globalThis.zxp = {
  h: __zxp_h,
  html: __htm_tag.bind(__zxp_h),
  args: [],
  flags: {},
  fs: {
    readFileSync: (path) => __native_readFileSync(path),
    writeFileSync: (path, buffer) => __native_writeFileSync(path, buffer),
  },

  async goto(url, options = {}) {
    applyLocationPolyfill(url);
    // JS handles the network — send mobile browser headers matching the scrape CLI path
    const res = await fetch(url, {
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        Accept:
          "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Upgrade-Insecure-Requests": "1",
      },
    });
    const html = await res.text();

    // Zig handles the Browser Pipeline (Parse, CSS, Scripts, Sanitize)
    __native_loadPage(html, {
      base_dir: url,
      sanitize: options.sanitize ?? false,
      execute_scripts: true,
      load_stylesheets: true,
      browser_profile: options.browser_profile ?? true,
    });
    if (
      globalThis.customElements &&
      typeof customElements.upgradeAll === "function"
    ) {
      customElements.upgradeAll();
    }

    // Drain the microtask queue so React/Vue can mount
    if (typeof __native_flush === "function") __native_flush();
  },

  // llmHTML(config) — call an LLM, stream HTML tokens, return the full HTML string.
  // config: { model, prompt, provider?, system?, base_url? }
  // provider defaults to "ollama" (http://localhost:11434)
  async llmHTML(config) {
    const raw = __native_llmHTML(config);
    // Strip markdown code fences that some models add despite instructions
    return raw.replace(/^```[\w]*\n?/, "").replace(/\n?```\s*$/, "").trim();
  },

  // llmStream(config) — call an LLM and feed each HTML token directly into the
  // lexbor streaming parser. The document is fully populated when this returns.
  // No HTML string accumulation; single parse pass; lower latency than llmHTML.
  // config: { model, prompt, provider?, system?, base_url? }
  llmStream(config) {
    __native_llmStream(config);
    if (
      globalThis.customElements &&
      typeof customElements.upgradeAll === "function"
    ) {
      customElements.upgradeAll();
    }
    if (typeof __native_flush === "function") __native_flush();
  },

  // streamFrom(url) — like goto(), but feeds the response directly into the
  // lexbor streaming parser instead of buffering the whole response first.
  // Use when the source is slow (LLM token stream, large SSR payload).
  // After this returns, `document` is fully populated (CSS + scripts applied).
  streamFrom(url, _options = {}) {
    applyLocationPolyfill(url);
    __native_streamFrom(url);
    if (
      globalThis.customElements &&
      typeof customElements.upgradeAll === "function"
    ) {
      customElements.upgradeAll();
    }
    if (typeof __native_flush === "function") __native_flush();
  },

  async waitForSelector(selector, timeoutMs = 5000) {
    const start = Date.now();
    return new Promise((resolve, reject) => {
      function poll() {
        const el = document.querySelector(selector);
        if (el) return resolve(el);
        if (Date.now() - start > timeoutMs)
          return reject(new Error(`Timeout: ${selector}`));

        __native_flush(); // Let React breathe
        Promise.resolve().then(poll);
      }
      poll();
    });
  },

  generateRoutePng(
    tiles,
    svgString,
    outputPath = null,
    width = 800,
    height = 600,
  ) {
    return __native_generateRoutePng(
      tiles,
      svgString,
      outputPath,
      width,
      height,
    );
  },

  /*
  paintDOM(node, opts?) → { data: ArrayBuffer (raw RGBA), width, height }
  opts: { width: 800 } | { dpi: 150 } | number (legacy width)
  */
  paintDOM(node, opts) {
    let w = 800;
    if (opts !== undefined && opts !== null) {
      if (typeof opts === "number") w = opts;
      else if (opts.width) w = opts.width;
      else if (opts.dpi) w = Math.round(8.2677 * opts.dpi);
    }
    return __native_paintDOM(node, w);
  },

  // save(img, path) — encode RGBA + write to disk; extension decides format
  // Supported: .png  .jpg/.jpeg  .webp  .pdf
  save(img, path) {
    __native_save(img.data, img.width, img.height, path);
  },

  /*
  Takes [url], [request_eaders: "Accept": "image/webp", "Authorization": "Bearer xyz" ]
  Returns array: [
  {ok: bool, // status 200–299
  status: number,    // HTTP status code 
  data: ArrayBuffer, // raw response body
  type: string,      // Content-Type from response headers
  }]
  */
  fetchAll(url_array, request_headers_array) {
    return __native_fetchAll(url_array, request_headers_array);
  },
  arrayBufferToBase64DataUri(buffer, type) {
    return __native_arrayBufferToBase64DataUri(buffer, type);
  },

  // encode(img, format) → ArrayBuffer — for server response or writeFileSync
  // format: "png" | "jpg" | "webp" | "pdf"  (default: "png")
  encode(img, format) {
    return __native_encode(img.data, img.width, img.height, format ?? "png");
  },

  loadHTML(html) {
    return __loadHTML(html);
  },

  pdf: {
    // SVG string → PDF ArrayBuffer (optionally saves to disk if outputPath given)
    async generateFromSvg(svgString, outputPath) {
      const blob = new Blob([svgString], { type: "image/svg+xml" });
      const bitmap = await createImageBitmap(blob);

      const doc = new PDFDocument();
      doc.addPage();
      doc.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height);
      if (outputPath) doc.save(outputPath);
      return doc.toArrayBuffer();
    },
  },
};

// ── Web Components Infrastructure ──────────────────────────────────────────

// The Headless HTMLElement Base with Constructor Hijacking.
// When a custom element is upgraded, the constructor returns the native
// C-backed Lexbor node directly instead of creating a ghost JS object.
let upgradingElement = null;

class HeadlessHTMLElement {
  constructor() {
    if (upgradingElement) {
      const el = upgradingElement;
      upgradingElement = null;
      return el;
    }
  }
}
if (globalThis.Element) {
  Object.setPrototypeOf(
    HeadlessHTMLElement.prototype,
    globalThis.Element.prototype,
  );
}
globalThis.HTMLElement = HeadlessHTMLElement;

// 2. The Custom Elements Registry.
globalThis.customElements = {
  _registry: new Map(),

  define(tagName, constructorClass) {
    const name = tagName.toUpperCase();
    this._registry.set(name, constructorClass);
    if (globalThis.document && document.readyState === "complete") {
      this.__upgradeElements(document.body, name, constructorClass);
    }
  },

  get(tagName) {
    return this._registry.get(tagName.toUpperCase());
  },

  upgradeAll() {
    if (!globalThis.document || !document.body) return;
    this._registry.forEach((constructorClass, tagName) => {
      this.__upgradeElements(document.body, tagName, constructorClass);
    });
  },

  __upgradeElements(rootNode, tagName, constructorClass) {
    const elements = rootNode.querySelectorAll(tagName.toLowerCase());

    for (let i = 0; i < elements.length; i++) {
      const el = elements[i];
      if (el.__isUpgraded) continue;

      Object.setPrototypeOf(el, constructorClass.prototype);

      // Constructor Hijack
      // Forces LitElement to initialize its reactive Symbols directly onto
      // the native C-backed Lexbor node.
      upgradingElement = el;
      try {
        const instance = new constructorClass();
        if (instance !== el) {
          // Fallback in case super() wasn't called properly
          Object.assign(el, instance);
        }
      } catch (err) {
        console.log(`[WC] Constructor failed for ${tagName}:`, err.message);
      } finally {
        upgradingElement = null;
      }

      el.__isUpgraded = true;

      // Feed HTML attributes into Lit
      if (
        constructorClass.observedAttributes &&
        typeof el.attributeChangedCallback === "function"
      ) {
        constructorClass.observedAttributes.forEach((attr) => {
          if (el.hasAttribute(attr)) {
            el.attributeChangedCallback(attr, null, el.getAttribute(attr));
          }
        });
      }

      // Fire the Web Component lifecycle
      if (typeof el.connectedCallback === "function") {
        el.connectedCallback();
      }
    }
  },
};

// 3. Dispatch DOMContentLoaded + load — called from Zig after scripts execute.
globalThis.__dispatchLoadEvent = function () {
  // Tell JS the document is fully parsed
  Object.defineProperty(Object.getPrototypeOf(document), "readyState", {
    get: () => "complete",
    configurable: true,
  });

  // Upgrade all custom elements that were parsed
  if (globalThis.customElements) {
    customElements.upgradeAll();
  }

  // Fire standard browser events (HTMX, React, etc. listen here)
  document.dispatchEvent(new Event("DOMContentLoaded", { bubbles: true }));
  window.dispatchEvent(new Event("load"));
};

// Hook createElement to auto-upgrade custom elements at creation time.
const originalCreateElement = document.createElement.bind(document);

document.createElement = function (tagName) {
  const el = originalCreateElement(tagName);
  const CustomClass = customElements.get(tagName);

  if (CustomClass) {
    Object.setPrototypeOf(el, CustomClass.prototype);
    el.__isUpgraded = true;
  }
  return el;
};
