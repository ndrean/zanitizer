// --- polyfills.js ---
// Browser environment compat shims for headless QuickJS.
// Loaded AFTER zexplorer.js so that HTMLElement = HeadlessHTMLElement
// when the event-handler polyfill runs.

// ── Environment Setup ──────────────────────────────────────────────────────

if (typeof window === "undefined") {
  globalThis.window = globalThis;
}
if (typeof self === "undefined") {
  globalThis.self = globalThis;
}
window.devicePixelRatio = window.devicePixelRatio || 1;

if (typeof globalThis.process === "undefined") {
  globalThis.process = { env: { NODE_ENV: "production" } };
}

// Document readyState — starts as "loading"; __dispatchLoadEvent sets "complete".
if (typeof document !== "undefined" && !document.readyState) {
  document.readyState = "loading";
}

// ── Global Event Listeners ─────────────────────────────────────────────────
// React/Preact attach listeners like "resize" and "unhandledrejection" here.

(function () {
  const listeners = new Map();

  globalThis.addEventListener = function (event, callback) {
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(callback);
  };

  globalThis.removeEventListener = function (event, callback) {
    if (listeners.has(event)) listeners.get(event).delete(callback);
  };

  globalThis.dispatchEvent = function (event) {
    if (listeners.has(event.type)) {
      listeners.get(event.type).forEach((cb) => {
        try {
          cb(event);
        } catch (e) {
          console.error(e);
        }
      });
    }
    return true;
  };
})();

// ── Browser Type Stubs ─────────────────────────────────────────────────────

if (typeof globalThis.ShadowRoot === "undefined") {
  globalThis.ShadowRoot = class ShadowRoot {};
}

if (typeof globalThis.HTMLIFrameElement === "undefined") {
  globalThis.HTMLIFrameElement = class HTMLIFrameElement {};
}

if (typeof globalThis.SVGElement === "undefined") {
  globalThis.SVGElement = class SVGElement {};
}

if (typeof globalThis.DOMException === "undefined") {
  class DOMException extends Error {
    constructor(message, name) {
      super(message);
      this.name = name || "DOMException";
      this.code = 0;
    }
  }
  globalThis.DOMException = DOMException;
}

if (typeof globalThis.AbortController === "undefined") {
  class AbortSignal {
    constructor() {
      this.aborted = false;
      this.onabort = null;
    }
  }
  class AbortController {
    constructor() {
      this.signal = new AbortSignal();
    }
    abort() {
      this.signal.aborted = true;
      if (this.signal.onabort) this.signal.onabort();
    }
  }
  globalThis.AbortController = AbortController;
  globalThis.AbortSignal = AbortSignal;
}

// ── DOM Stubs ──────────────────────────────────────────────────────────────
// Namespace-aware attribute stubs.
// Lexbor doesn't track XML namespaces; delegate to plain attribute API.
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
if (!globalThis.Element.prototype.createSVGMatrix) {
  globalThis.Element.prototype.createSVGMatrix = function () {
    return new SVGMatrix();
  };
}
// Leaflet asks paths for their bounding box — return a fake empty rect.
if (!globalThis.Element.prototype.getBBox) {
  globalThis.Element.prototype.getBBox = function () {
    return new SVGRect();
  };
}

globalThis.Range.prototype.createContextualFragment = function (htmlString) {
  const template = document.createElement("template");
  template.innerHTML = htmlString;
  return template.content;
};

if (!globalThis.Element.prototype.attachShadow) {
  globalThis.Element.prototype.attachShadow = function (options) {
    this.shadowRoot = this;
    return this;
  };
}

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

// ── CSS Stubs ──────────────────────────────────────────────────────────────

globalThis.CSSStyleSheet =
  globalThis.CSSStyleSheet ||
  class CSSStyleSheet {
    replaceSync() {}
    replace() {
      return Promise.resolve(this);
    }
  };

if (!globalThis.Document) globalThis.Document = class Document {};

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

// ── Layout / Viewport Stubs ────────────────────────────────────────────────

window.matchMedia =
  window.matchMedia ||
  function (query) {
    return {
      matches: false,
      media: query,
      onchange: null,
      addListener: function () {},
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

// Tell frameworks everything is visible so they hydrate all elements.
class IntersectionObserver {
  constructor(callback, options) {
    this.callback = callback;
  }
  observe(target) {
    Promise.resolve().then(() => {
      this.callback([
        { isIntersecting: true, target: target, intersectionRatio: 1.0 },
      ]);
    });
  }
  unobserve(target) {}
  disconnect() {}
}
window.IntersectionObserver = window.IntersectionObserver || IntersectionObserver;

window.scrollTo = window.scrollTo || function () {};
window.scrollBy = window.scrollBy || function () {};

// ── XPath ──────────────────────────────────────────────────────────────────
// HTMX 2.x uses XPath to find elements with hx-on:* attributes.
// Minimal evaluator: handles starts-with(name(), "prefix") patterns.

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

// ── Async Scheduling ───────────────────────────────────────────────────────

(function () {
  let callbacks = [];
  let pending = false;
  let idCounter = 0;

  globalThis.requestAnimationFrame = function (callback) {
    const id = ++idCounter;
    callbacks.push({ id, callback });
    if (!pending) {
      pending = true;
      Promise.resolve().then(function () {
        pending = false;
        const now = Date.now();
        const cbs = callbacks;
        callbacks = [];
        for (let ci = 0; ci < cbs.length; ci++) {
          const item = cbs[ci];
          try {
            item.callback(now);
          } catch (e) {
            console.log("RAF error:", e);
            if (e && e.message) console.log("  msg:", e.message);
            if (e && e.stack)
              console.log(
                "  stack:",
                e.stack.split("\n").slice(0, 5).join("\n"),
              );
          }
        }
      });
    }
    return id;
  };

  globalThis.cancelAnimationFrame = function (id) {
    callbacks = callbacks.filter((cb) => cb.id !== id);
  };
})();

// ── Messaging ──────────────────────────────────────────────────────────────
// React 19 scheduler uses MessageChannel for microtask scheduling.

(function () {
  if (typeof globalThis.MessageEvent === "undefined") {
    class MessageEvent {
      constructor(type, init) {
        this.type = type || "message";
        this.data = init && init.data !== undefined ? init.data : null;
        this.origin = (init && init.origin) || "";
        this.lastEventId = (init && init.lastEventId) || "";
        this.source = (init && init.source) || null;
        this.ports = (init && init.ports) || [];
        this.bubbles = false;
        this.cancelable = false;
      }
    }
    globalThis.MessageEvent = MessageEvent;
  }

  if (globalThis.MessageChannel) return;

  class MessagePort {
    constructor() {
      this.onmessage = null;
      this._other = null;
      this._closed = false;
      this._queue = [];
    }
    postMessage(data) {
      if (this._closed) return;
      if (this._other) {
        this._other._queue.push(data);
        Promise.resolve().then(() => {
          if (
            this._other &&
            !this._other._closed &&
            this._other.onmessage
          ) {
            const message = this._other._queue.shift();
            if (message !== undefined) {
              try {
                this._other.onmessage(
                  new MessageEvent("message", { data: message }),
                );
              } catch (e) {
                console.log("Error in MessagePort onmessage:", e);
              }
            }
          }
        });
      }
    }
    start() {}
    close() {
      if (!this._closed) {
        this._closed = true;
        if (this._other) this._other.close();
      }
    }
  }

  class MessageChannel {
    constructor() {
      this.port1 = new MessagePort();
      this.port2 = new MessagePort();
      this.port1._other = this.port2;
      this.port2._other = this.port1;
    }
  }
  globalThis.MessageChannel = MessageChannel;
  globalThis.MessagePort = MessagePort;
})();

// ── Observers ──────────────────────────────────────────────────────────────

(function () {
  if (globalThis.MutationObserver) return;
  class MutationObserver {
    constructor(callback) {}
    observe(target, options) {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }
  globalThis.MutationObserver = MutationObserver;
})();

// ── ES2022 Polyfills ───────────────────────────────────────────────────────

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

// ── Event Handler Properties ───────────────────────────────────────────────
// Adds onclick, onkeydown, etc. to HTMLElement.prototype (= HeadlessHTMLElement).
// Guard: only runs if HTMLElement is defined (it is — zexplorer.js sets it first).

if (typeof HTMLElement !== "undefined") {
  const events = [
    "click",
    "dblclick",
    "mousedown",
    "mouseup",
    "mouseover",
    "mouseout",
    "mousemove",
    "mouseenter",
    "mouseleave",
    "keydown",
    "keyup",
    "keypress",
    "submit",
    "input",
    "change",
    "focus",
    "blur",
    "load",
    "error",
    "scroll",
    "resize",
  ];

  events.forEach((event) => {
    const prop = "on" + event;
    const privateProp = "_" + prop;
    const guardProp = "__guard_" + prop;

    Object.defineProperty(HTMLElement.prototype, prop, {
      configurable: true,
      enumerable: true,
      get() {
        return this[privateProp] || null;
      },
      set(handler) {
        if (this[guardProp]) return;
        this[guardProp] = true;
        try {
          if (this[privateProp]) {
            this.removeEventListener(event, this[privateProp]);
          }
          if (typeof handler === "function") {
            this[privateProp] = handler;
            this.addEventListener(event, handler);
          } else {
            this[privateProp] = null;
          }
        } finally {
          this[guardProp] = false;
        }
      },
    });
  });
}
