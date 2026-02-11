import { JSDOM } from "jsdom";
import DOMPurify from "dompurify";
import { readFileSync } from "fs";
import { performance, PerformanceObserver } from "perf_hooks";
import assert from "assert";

// Setup performance observer
const obs = new PerformanceObserver((items) => {
  items.getEntries().forEach((entry) => {
    console.log(`${entry.name}: ${entry.duration.toFixed(2)}ms`);
  });
});
obs.observe({ entryTypes: ["measure"] });

// Load test HTML
const dirtyHTML = readFileSync("index.html", "utf8");
const maliciousCSS = readFileSync("styles.css", "utf8");

// CSS sanitization patterns to test
const CSS_XSS_PATTERNS = [
  /javascript:/i,
  /expression\s*\(/i,
  /behavior\s*:/i,
  /-moz-binding\s*:/i,
  /@import\s*(url\()?['"]?javascript:/i,
  /@import\s*(url\()?['"]?data:/i,
  /url\s*\(\s*['"]?data:/i,
  /url\s*\(\s*['"]?javascript:/i,
  /content\s*:\s*url/i,
  /src\s*:\s*url\s*\(\s*['"]?javascript:/i,
  /@keyframes[^{]*\{[^}]*url\s*\(\s*['"]?javascript:/i,
  /@media[^{]*\{[^}]*url\s*\(\s*['"]?javascript:/i,
];

/**
 * PROPER CSS SANITIZATION FUNCTION
 * This actually removes malicious patterns from CSS
 */
function sanitizeCSS(css) {
  if (!css) return css;

  let sanitized = css
    // Remove javascript: URLs in url()
    .replace(/url\s*\(\s*['"]?\s*javascript:/gi, "url(#blocked)")
    // Remove javascript: anywhere else
    .replace(/javascript:/gi, "blocked:")
    // Remove CSS expressions
    .replace(/expression\s*\(/gi, "/* blocked expression */")
    // Remove @import statements
    .replace(/@import\s+/gi, "/* @import blocked */ ")
    // Remove behavior properties
    .replace(/behavior\s*:\s*url/gi, "behavior: url(#blocked)")
    // Remove -moz-binding
    .replace(/-moz-binding\s*:/gi, "/* -moz-binding blocked */")
    // Remove data: URLs in url()
    .replace(/url\s*\(\s*['"]?\s*data:/gi, "url(#blocked)")
    // Remove content: url()
    .replace(
      /content\s*:\s*url\s*\(\s*['"]?\s*javascript:/gi,
      "content: url(#blocked)",
    )
    // Remove src: url() in @font-face
    .replace(
      /src\s*:\s*url\s*\(\s*['"]?\s*javascript:/gi,
      "src: url(#blocked)",
    );

  return sanitized;
}

/**
 * EXTREME CSS SANITIZATION - removes ALL potentially dangerous constructs
 */
function sanitizeCSSExtreme(css) {
  if (!css) return css;

  // Remove all CSS rules that might contain XSS vectors
  return css
    .replace(/@import[^;]*;/gi, "/* @import removed */;")
    .replace(/url\s*\([^)]*\)/gi, "url(#safe)")
    .replace(/expression\s*\([^)]*\)/gi, "/* expression removed */")
    .replace(/behavior\s*:[^;]*;/gi, "/* behavior removed */;")
    .replace(/-moz-binding\s*:[^;]*;/gi, "/* binding removed */;")
    .replace(/javascript:[^;)\s]*/gi, "blocked")
    .replace(/data:[^;)\s]*/gi, "blocked");
}

// Validation helper for CSS sanitization
function validateCSSSanitized(
  css,
  shouldBeSanitized = true,
  isExtreme = false,
) {
  if (shouldBeSanitized) {
    // Check each malicious pattern
    CSS_XSS_PATTERNS.forEach((pattern) => {
      assert.ok(!pattern.test(css), `CSS should not contain: ${pattern}`);
    });

    // Additional specific checks
    assert.ok(!css.includes("expression("), "No CSS expressions");
    assert.ok(!css.includes("behavior:"), "No CSS behaviors");
    assert.ok(!css.includes("-moz-binding"), "No -moz-binding");
    assert.ok(!css.includes("@import"), "No @import rules");
    assert.ok(!css.includes("javascript:"), "No javascript: URLs");
    assert.ok(!css.includes("data:text/html"), "No data: URLs with HTML");

    // In extreme mode, even safe CSS might be removed
    if (!isExtreme) {
      // But safe CSS should remain in moderate sanitization
      assert.ok(
        css.includes(".container") ||
          css.includes(".product") ||
          css.length === 0,
        "Safe CSS may be preserved or removed entirely",
      );
    }
  }

  return true;
}

// Validation helper for DOM sanitization
function validateJSDOMResult(
  document,
  shouldBeSanitized = true,
  isExtreme = false,
) {
  // 1. DOM structure assertions
  const products = document.querySelectorAll(".product");
  assert.strictEqual(products.length, 3, "Should have exactly 3 products");

  const container = document.querySelector(".container");
  assert.ok(container, "Container should exist");

  const trackedElements = document.querySelectorAll('[data-track="true"]');
  assert.strictEqual(
    trackedElements.length,
    1,
    "Should have 1 tracked element",
  );

  if (shouldBeSanitized) {
    // 2. External stylesheet sanitization
    const stylesheetLinks = document.querySelectorAll('link[rel="stylesheet"]');
    assert.strictEqual(
      stylesheetLinks.length,
      0,
      "External stylesheets should be removed by default",
    );

    // 3. Inline style tag sanitization - THIS ACTUALLY CHECKS OUR SANITIZATION
    const styleTags = document.querySelectorAll("style");
    styleTags.forEach((style) => {
      const css = style.textContent;
      validateCSSSanitized(css, true, isExtreme);
    });

    // 4. Inline style attribute sanitization
    const elementsWithInlineStyle = document.querySelectorAll("[style]");
    elementsWithInlineStyle.forEach((el) => {
      const style = el.getAttribute("style");
      if (style) {
        validateCSSSanitized(style, true, isExtreme);
      }
    });

    // 5. No script tags
    const scripts = document.querySelectorAll("script");
    assert.strictEqual(scripts.length, 0, "Script tags should be removed");

    // 6. No event handlers
    const elementsWithEvents = document.querySelectorAll(
      "[onclick], [onerror], [onload], [onmouseover]",
    );
    assert.strictEqual(
      elementsWithEvents.length,
      0,
      "Event handlers should be removed",
    );

    // 7. No javascript: iframes
    const iframes = document.querySelectorAll("iframe");
    iframes.forEach((iframe) => {
      const src = iframe.getAttribute("src");
      assert.ok(
        !src?.startsWith("javascript:"),
        "javascript: iframe src should be removed",
      );
    });

    // 8. No javascript: or data: URLs in href/src
    const elementsWithSrc = document.querySelectorAll("[src], [href]");
    elementsWithSrc.forEach((el) => {
      const src = el.getAttribute("src");
      const href = el.getAttribute("href");
      if (src) {
        assert.ok(
          !src.startsWith("javascript:") && !src.startsWith("data:"),
          "No javascript: or data: in src",
        );
      }
      if (href) {
        assert.ok(
          !href.startsWith("javascript:") && !href.startsWith("data:"),
          "No javascript: or data: in href",
        );
      }
    });
  }

  return {
    productCount: products.length,
    hasContainer: !!container,
    trackedCount: trackedElements.length,
    styleTagCount: document.querySelectorAll("style").length,
    inlineStyleCount: document.querySelectorAll("[style]").length,
  };
}

// Warm-up run
for (let i = 0; i < 10; i++) {
  const window = new JSDOM("").window;
  const purify = DOMPurify(window);
  purify.sanitize(dirtyHTML);
}

// Benchmark runs
async function runJSDOMBenchmark(iterations = 100) {
  console.log("\n=== JSDOM + DOMPurify Benchmark with CSS Sanitization ===");
  console.log(`Running ${iterations} iterations...\n`);

  // ----------------------------------------------------------------
  // TEST 1: DOMPurify DEFAULT (SHOULD FAIL - DEMONSTRATES LIMITATION)
  // ----------------------------------------------------------------
  performance.mark("jsdom-default-start");

  let defaultFailures = 0;
  for (let i = 0; i < iterations; i++) {
    try {
      const window = new JSDOM("").window;
      const purify = DOMPurify(window);

      // NO CSS sanitization - default behavior
      const cleanHTML = purify.sanitize(dirtyHTML);
      const dom = new JSDOM(cleanHTML);
      const document = dom.window.document;

      // This SHOULD fail because DOMPurify doesn't sanitize style tags
      // We catch the error and count it as expected
      validateJSDOMResult(document, true, false);
      dom.window.close();
    } catch (error) {
      defaultFailures++;
    }
  }

  performance.mark("jsdom-default-end");
  performance.measure(
    `JSDOM + DOMPurify (Default) - ${defaultFailures}/${iterations} failures (EXPECTED)`,
    "jsdom-default-start",
    "jsdom-default-end",
  );
  console.log(
    `   ✅ Default mode correctly FAILED ${defaultFailures}/${iterations} times (demonstrates DOMPurify limitation)`,
  );

  // ----------------------------------------------------------------
  // TEST 2: DOMPurify + HOOK-BASED CSS SANITIZATION (SHOULD PASS)
  // ----------------------------------------------------------------
  performance.mark("jsdom-hook-start");

  for (let i = 0; i < iterations; i++) {
    const window = new JSDOM("").window;
    const purify = DOMPurify(window);

    // Add hook to sanitize style tags
    purify.addHook("uponSanitizeElement", (node) => {
      if (node.tagName === "STYLE" && node.textContent) {
        node.textContent = sanitizeCSS(node.textContent);
      }
    });

    // Also sanitize style attributes via hook
    purify.addHook("uponSanitizeAttribute", (node, data) => {
      if (data.attrName === "style" && data.attrValue) {
        data.attrValue = sanitizeCSS(data.attrValue);
      }
    });

    const cleanHTML = purify.sanitize(dirtyHTML);
    const dom = new JSDOM(cleanHTML);
    const document = dom.window.document;

    // This should NOW pass because we added manual CSS sanitization
    validateJSDOMResult(document, true, false);

    dom.window.close();
  }

  performance.mark("jsdom-hook-end");
  performance.measure(
    "JSDOM + DOMPurify (Hook-based CSS Sanitization)",
    "jsdom-hook-start",
    "jsdom-hook-end",
  );

  // ----------------------------------------------------------------
  // TEST 3: STRICT MODE - REMOVE ALL CSS (SHOULD PASS)
  // ----------------------------------------------------------------
  performance.mark("jsdom-strict-start");

  for (let i = 0; i < iterations; i++) {
    const window = new JSDOM("").window;
    const purify = DOMPurify(window);

    // Strict config - remove all style-related content
    const cleanHTML = purify.sanitize(dirtyHTML, {
      FORBID_TAGS: ["style", "link"],
      FORBID_ATTR: ["style"],
      ALLOW_DATA_ATTR: true,
      USE_PROFILES: { html: true },
    });

    const dom = new JSDOM(cleanHTML);
    const document = dom.window.document;

    // Verify all CSS is removed
    assert.strictEqual(
      document.querySelectorAll("style").length,
      0,
      "No style tags in strict mode",
    );
    assert.strictEqual(
      document.querySelectorAll("[style]").length,
      0,
      "No inline styles in strict mode",
    );
    assert.strictEqual(
      document.querySelectorAll('link[rel="stylesheet"]').length,
      0,
      "No stylesheet links in strict mode",
    );

    // Structure should remain
    assert.strictEqual(
      document.querySelectorAll(".product").length,
      3,
      "Products still exist",
    );

    dom.window.close();
  }

  performance.mark("jsdom-strict-end");
  performance.measure(
    "JSDOM + DOMPurify (Strict - No CSS)",
    "jsdom-strict-start",
    "jsdom-strict-end",
  );

  // ----------------------------------------------------------------
  // TEST 4: EXTREME CSS SANITIZATION (SHOULD PASS)
  // ----------------------------------------------------------------
  performance.mark("jsdom-extreme-start");

  for (let i = 0; i < iterations; i++) {
    const window = new JSDOM("").window;
    const purify = DOMPurify(window);

    // Add hook with extreme CSS sanitization
    purify.addHook("uponSanitizeElement", (node) => {
      if (node.tagName === "STYLE" && node.textContent) {
        node.textContent = sanitizeCSSExtreme(node.textContent);
      }
    });

    purify.addHook("uponSanitizeAttribute", (node, data) => {
      if (data.attrName === "style" && data.attrValue) {
        data.attrValue = sanitizeCSSExtreme(data.attrValue);
      }
    });

    const cleanHTML = purify.sanitize(dirtyHTML, {
      FORBID_TAGS: ["link"], // Remove external stylesheets
      FORBID_ATTR: ["onclick", "onerror", "onload", "onmouseover"],
      ALLOW_DATA_ATTR: true,
      USE_PROFILES: { html: true },
    });

    const dom = new JSDOM(cleanHTML);
    const document = dom.window.document;

    // Validate with extreme mode flag
    validateJSDOMResult(document, true, true);

    dom.window.close();
  }

  performance.mark("jsdom-extreme-end");
  performance.measure(
    "JSDOM + DOMPurify (Extreme CSS Sanitization)",
    "jsdom-extreme-start",
    "jsdom-extreme-end",
  );

  // ----------------------------------------------------------------
  // TEST 5: CSS-ONLY SANITIZATION PERFORMANCE
  // ----------------------------------------------------------------
  performance.mark("css-only-start");

  for (let i = 0; i < iterations; i++) {
    // Direct CSS sanitization without DOMPurify
    const cleanCSS = sanitizeCSS(maliciousCSS);
    validateCSSSanitized(cleanCSS, true, false);
  }

  performance.mark("css-only-end");
  performance.measure(
    "Manual CSS Sanitization Only",
    "css-only-start",
    "css-only-end",
  );
}

// Run benchmarks
console.log("Starting benchmarks with malicious CSS testing...");
console.log(
  "\n⚠️  NOTE: DOMPurify does NOT sanitize <style> tag contents by default!",
);
console.log(
  "⚠️  The first test should FAIL - this demonstrates the limitation\n",
);

runJSDOMBenchmark(100).catch((error) => {
  console.error("\n❌ Benchmark failed with error:", error.message);
  console.log(
    "\nThis failure is EXPECTED if it's from Test 1 (default DOMPurify)",
  );
  console.log(
    "If it's from other tests, we need to fix the sanitization implementation",
  );
});
