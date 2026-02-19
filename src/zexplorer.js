// --- zexplorer.js (Embedded in Zig, runs on boot) ---

if (typeof window === "undefined") {
  globalThis.window = globalThis;
}
if (typeof self === "undefined") {
  globalThis.self = globalThis;
}

// navigator is set in Zig (js_polyfills.install) with a full Chrome-like userAgent
window.devicePixelRatio = window.devicePixelRatio || 1;

// ShadowRoot stub — HTMX checks `instanceof ShadowRoot` during DOM processing.
// No real shadow DOM support, just prevent ReferenceError.
if (typeof globalThis.ShadowRoot === "undefined") {
  globalThis.ShadowRoot = class ShadowRoot {};
}

// Document readyState — starts as "loading", frameworks check this to decide
// whether to init immediately or wait for DOMContentLoaded.
// The script engine fires DOMContentLoaded after all scripts execute.
if (typeof document !== "undefined" && !document.readyState) {
  document.readyState = "loading";
}

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

// Namespace-aware attribute stubs: lexbor doesn't track XML namespaces,
// so we ignore the namespace URI and delegate to the plain attribute API.
// Needed by D3, Snap.svg, and any library that builds SVG via the DOM.
if (!globalThis.Element.prototype.setAttributeNS) {
  globalThis.Element.prototype.setAttributeNS = function (ns, name, value) {
    this.setAttribute(name, value);
  };
}
if (!globalThis.Element.prototype.getAttributeNS) {
  globalThis.Element.prototype.getAttributeNS = function (ns, name) {
    return this.getAttribute(name);
  };
}
if (!globalThis.Element.prototype.removeAttributeNS) {
  globalThis.Element.prototype.removeAttributeNS = function (ns, name) {
    this.removeAttribute(name);
  };
}

globalThis.SVGRect = function () {
  this.x = 0;
  this.y = 0;
  this.width = 0;
  this.height = 0;
};

// Attach it to all Elements (safest headless fallback)
if (!globalThis.Element.prototype.createSVGRect) {
  globalThis.Element.prototype.createSVGRect = function () {
    return new SVGRect();
  };
}

globalThis.SVGRect = function () {
  this.x = 0;
  this.y = 0;
  this.width = 0;
  this.height = 0;
};
globalThis.SVGMatrix = function () {
  this.a = 1;
  this.b = 0;
  this.c = 0;
  this.d = 1;
  this.e = 0;
  this.f = 0;
};

if (!globalThis.Element.prototype.createSVGRect) {
  globalThis.Element.prototype.createSVGRect = function () {
    return new SVGRect();
  };
}

globalThis.Range.prototype.createContextualFragment = function (htmlString) {
  const template = document.createElement("template");
  template.innerHTML = htmlString;
  return template.content; // Returns a DocumentFragment
};

if (!globalThis.Element.prototype.createSVGMatrix) {
  globalThis.Element.prototype.createSVGMatrix = function () {
    return new SVGMatrix();
  };
}

// Leaflet sometimes asks paths for their bounding box.
// We return a fake empty rect to prevent crashes.
if (!globalThis.Element.prototype.getBBox) {
  globalThis.Element.prototype.getBBox = function () {
    return new SVGRect();
  };
}

// XPathEvaluator — HTMX 2.x uses XPath to find elements with hx-on:* attributes.
// We implement a minimal evaluator that handles starts-with(name(), "prefix") patterns
// by walking the DOM tree and checking attribute names. This covers HTMX's single query.
globalThis.XPathEvaluator =
  globalThis.XPathEvaluator ||
  (() => {
    function parseAttrPrefixes(expr) {
      const prefixes = [];
      const re = /starts-with\s*\(\s*name\s*\(\s*\)\s*,\s*"([^"]+)"\s*\)/g;
      let m;
      while ((m = re.exec(expr)) !== null) prefixes.push(m[1]);
      return prefixes;
    }

    function walkElements(root, prefixes) {
      const results = [];
      const all = root.querySelectorAll("*");
      for (let j = 0; j < all.length; j++) {
        const node = all[j];
        if (!node.attributes) continue;
        for (let i = 0; i < node.attributes.length; i++) {
          const attrName = node.attributes[i].name;
          for (const pfx of prefixes) {
            if (attrName.startsWith(pfx)) {
              results.push(node);
              i = node.attributes.length;
              break;
            }
          }
        }
      }
      return results;
    }

    function makeResult(nodes) {
      let idx = 0;
      return {
        snapshotLength: nodes.length,
        snapshotItem: (i) => nodes[i] || null,
        iterateNext: () => (idx < nodes.length ? nodes[idx++] : null),
      };
    }

    class XPathEvaluator {
      createExpression(expr) {
        const prefixes = parseAttrPrefixes(expr);
        return {
          evaluate: (contextNode) =>
            makeResult(
              prefixes.length ? walkElements(contextNode, prefixes) : [],
            ),
        };
      }
      evaluate(expr, contextNode) {
        const prefixes = parseAttrPrefixes(expr);
        return makeResult(
          prefixes.length ? walkElements(contextNode, prefixes) : [],
        );
      }
    }
    return XPathEvaluator;
  })();
if (!document.evaluate) {
  const evaluator = new XPathEvaluator();
  document.evaluate = function (expr, contextNode) {
    return evaluator.evaluate(expr, contextNode);
  };
}

window.matchMedia =
  window.matchMedia ||
  function (query) {
    return {
      matches: false, // Defaulting to desktop/false is usually safest
      media: query,
      onchange: null,
      addListener: function () {}, // Legacy, but React still calls it
      removeListener: function () {},
      addEventListener: function () {},
      removeEventListener: function () {},
      dispatchEvent: function () {
        return false;
      },
    };
  };

class ResizeObserver {
  constructor(callback) {
    this.callback = callback;
  }
  observe(target) {}
  unobserve(target) {}
  disconnect() {}
}
window.ResizeObserver = window.ResizeObserver || ResizeObserver;

// we tell the framework that everything is visible to hydrate and get
// acces to all elements.
class IntersectionObserver {
  constructor(callback, options) {
    this.callback = callback;
  }
  observe(target) {
    // Fire the callback in the next microtask, pretending it just scrolled into view
    Promise.resolve().then(() => {
      this.callback([
        {
          isIntersecting: true,
          target: target,
          intersectionRatio: 1.0,
        },
      ]);
    });
  }
  unobserve(target) {}
  disconnect() {}
}
window.IntersectionObserver =
  window.IntersectionObserver || IntersectionObserver;

window.scrollTo = window.scrollTo || function () {};
window.scrollBy = window.scrollBy || function () {};

// // --- DocumentFragment Unpacker Polyfill ---
// // C-based DOM engines often drop parent pointers for Comment/Text nodes
// // when appending DocumentFragments. This unpacks them in pure JS to guarantee
// // the C-bridge correctly links every single Lit marker node!
// (function () {
//   const proto = globalThis.Node
//     ? globalThis.Node.prototype
//     : globalThis.Element.prototype;

//   const origAppend = proto.appendChild;
//   if (origAppend) {
//     proto.appendChild = function (child) {
//       if (child && child.nodeType === 11) {
//         // 11 = DocumentFragment
//         while (child.firstChild) {
//           origAppend.call(this, child.firstChild);
//         }
//         return child;
//       }
//       return origAppend.call(this, child);
//     };
//   }

//   const origInsert = proto.insertBefore;
//   if (origInsert) {
//     proto.insertBefore = function (child, ref) {
//       if (child && child.nodeType === 11) {
//         while (child.firstChild) {
//           origInsert.call(this, child.firstChild, ref);
//         }
//         return child;
//       }
//       return origInsert.call(this, child, ref);
//     };
//   }
// })();

globalThis.zexplorer = {
  fs: {
    writeFileSync: (path, buffer) => __native_writeFileSync(path, buffer),
  },
  async goto(url, options = { sanitize: false }) {
    applyLocationPolyfill(url);
    // JS handles the network (easy to add headers, cookies, etc.)
    const res = await fetch(url);
    const html = await res.text();

    // Zig handles the Browser Pipeline (Parse, CSS, Scripts, Sanitize)
    __native_loadPage(html, {
      base_dir: url,
      // base_dir: new URL(".", url).href, // Web compliant URL API
      sanitize: options.sanitize,
      execute_scripts: true,
      load_stylesheets: true,
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

  pdf: {
    async generate(svgString, outputPath) {
      // Wraps LibHaru/ThorVG logic
      const blob = new Blob([svgString], { type: "image/svg+xml" });
      const bitmap = await createImageBitmap(blob);

      const doc = new PDFDocument();
      doc.addPage();
      doc.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height);
      doc.save(outputPath);
      return doc.toArrayBuffer();
    },
  },
};

// WebComponents
// if (
//   !Object.getOwnPropertyDescriptor(globalThis.Node.prototype, "isConnected")
// ) {
//   Object.defineProperty(globalThis.Node.prototype, "isConnected", {
//     get() {
//       return true;
//     },
//   });
// }

// 1. ShadowRoot stub — Fallback for attachShadow
if (!globalThis.Element.prototype.attachShadow) {
  globalThis.Element.prototype.attachShadow = function (options) {
    this.shadowRoot = this;
    return this;
  };
}

// 2. The Headless HTMLElement Base with Constructor Hijacking
let upgradingElement = null;

class HeadlessHTMLElement {
  constructor() {
    // If we are currently upgrading an element, hijack the constructor!
    // The 'new' keyword will abort creating a ghost JS object and instead
    // return the native C-backed Lexbor node directly to LitElement.
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

// 2. The Custom Elements Registry
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
    console.log("UPGRADEALL");
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
      console.log(el);

      // Step 1: Morph the prototype
      Object.setPrototypeOf(el, constructorClass.prototype);

      // Step 2: The Constructor Hijack!
      // This forces LitElement to initialize all its internal reactive Symbols
      // and microtasks directly onto the native C-backed Lexbor node!
      upgradingElement = el;
      try {
        // This invokes HeadlessHTMLElement, which returns 'el'!
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

      // Step 3: Feed HTML attributes into Lit
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

      // Step 4: Fire the Web Component lifecycle
      if (typeof el.connectedCallback === "function") {
        el.connectedCallback();
      }
    }
  },
};

globalThis.CSSStyleSheet =
  globalThis.CSSStyleSheet ||
  class CSSStyleSheet {
    replaceSync() {}
    replace() {
      return Promise.resolve(this);
    }
  };

// Ensure Document exists so prototype access doesn't crash
if (!globalThis.Document) globalThis.Document = class Document {};

// Stub adoptedStyleSheets to safely bypass the modern CSS engine
if (!globalThis.Document.prototype.adoptedStyleSheets) {
  Object.defineProperty(globalThis.Document.prototype, "adoptedStyleSheets", {
    get: () => [],
    set: () => {},
  });
  Object.defineProperty(globalThis.Element.prototype, "adoptedStyleSheets", {
    get: () => [],
    set: () => {},
  });
}

globalThis.__dispatchLoadEvent = function () {
  // 1. Tell JS the document is fully parsed
  Object.defineProperty(Object.getPrototypeOf(document), "readyState", {
    get: () => "complete",
    configurable: true,
  });

  // 2. Upgrade all custom elements that were parsed
  if (globalThis.customElements) {
    customElements.upgradeAll();
  }

  // 3. Fire standard browser events for libraries like HTMX
  document.dispatchEvent(new Event("DOMContentLoaded", { bubbles: true }));
  window.dispatchEvent(new Event("load"));
};

// Hook 1: Override createElement
const originalCreateElement = document.createElement.bind(document);

document.createElement = function (tagName) {
  const el = originalCreateElement(tagName);
  const CustomClass = customElements.get(tagName);

  if (CustomClass) {
    Object.setPrototypeOf(el, CustomClass.prototype);
    el.__isUpgraded = true;
    // Note: connectedCallback usually fires when appended to the document,
    // so you might hook into `appendChild` to fire it perfectly,
    // but doing it here works for most headless scripts.
  }
  return el;
};

// importNode is now a native binding in dom_bridge.zig
// Uses lexbor's lxb_dom_document_import_node for proper ownerDocument adoption

// node.append()
if (!globalThis.Element.prototype.append) {
  const appendFn = function (...nodes) {
    for (const node of nodes) {
      this.appendChild(
        typeof node === "string" ? document.createTextNode(node) : node,
      );
    }
  };
  globalThis.Element.prototype.append = appendFn;
  globalThis.DocumentFragment.prototype.append = appendFn;
}

// Missing ES22 methods
// 1. Array/String .at() (Extremely common cause of "not a function" in modern Lit)
if (!Array.prototype.at) {
  const atFn = function (n) {
    n = Math.trunc(n) || 0;
    if (n < 0) n += this.length;
    if (n < 0 || n >= this.length) return undefined;
    return this[n];
  };
  Object.defineProperty(Array.prototype, "at", {
    value: atFn,
    writable: true,
    configurable: true,
  });
  Object.defineProperty(String.prototype, "at", {
    value: atFn,
    writable: true,
    configurable: true,
  });
}

// 2. String.prototype.replaceAll
if (!String.prototype.replaceAll) {
  String.prototype.replaceAll = function (str, newStr) {
    if (
      Object.prototype.toString.call(str).toLowerCase() === "[object regexp]"
    ) {
      return this.replace(str, newStr);
    }
    return this.replace(
      new RegExp(str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"),
      newStr,
    );
  };
}

// 3. String.prototype.matchAll (Used heavily by template parsers)
if (!String.prototype.matchAll) {
  String.prototype.matchAll = function* (regex) {
    const globalRegex = new RegExp(
      regex,
      regex.flags.includes("g") ? regex.flags : regex.flags + "g",
    );
    let match;
    while ((match = globalRegex.exec(this)) !== null) {
      yield match;
    }
  };
}

// 4. Object.hasOwn (Replaces hasOwnProperty in ES2022)
if (!Object.hasOwn) {
  Object.defineProperty(Object, "hasOwn", {
    value: function (obj, prop) {
      if (obj == null)
        throw new TypeError("Cannot convert undefined or null to object");
      return Object.prototype.hasOwnProperty.call(Object(obj), prop);
    },
    configurable: true,
    writable: true,
  });
}
