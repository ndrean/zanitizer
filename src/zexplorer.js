// --- zexplorer.js (Embedded in Zig, runs on boot) ---

if (typeof window === "undefined") {
  globalThis.window = globalThis;
}
if (typeof self === "undefined") {
  globalThis.self = globalThis;
}

// navigator is set in Zig (js_polyfills.install) with a full Chrome-like userAgent
window.devicePixelRatio = window.devicePixelRatio || 1;

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

globalThis.SVGRect = function () {
  this.x = 0;
  this.y = 0;
  this.width = 0;
  this.height = 0;
};

// 2. Attach it to all Elements (safest headless fallback)
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
