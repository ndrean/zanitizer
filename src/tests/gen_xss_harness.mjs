#!/usr/bin/env node
/**
 * gen_xss_harness.mjs — Generate a browser XSS harness from test vectors.
 *
 * Reads tests/input/dompurify_tests.json, instruments each payload so that
 * any surviving alert() call is uniquely tagged with the test index, sanitizes
 * with zanitize WASM, and embeds all sanitized fragments into a single static
 * HTML file.
 *
 * In the browser, window.alert/confirm/prompt/fetch are overridden in <head>
 * (before the body parses) so that:
 *   - <script> tags that survive sanitization execute and are caught
 *   - onerror/onload handlers that survive fire on load and are caught
 *   - After load, synthetic events are dispatched to trigger onclick/onmouseover etc.
 *
 * Usage:
 *   node tests/gen_xss_harness.mjs [output.html]
 *   # Default output: tests/output/xss_harness.html
 */

import { loadZanitize } from '../wasm-out/zanitize.js';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const __dir = dirname(fileURLToPath(import.meta.url));
const outPath = process.argv[2] ?? resolve(__dir, 'output/xss_harness.html');

// ── Load test vectors ──────────────────────────────────────────────────────

const tests = JSON.parse(
  readFileSync(resolve(__dir, 'input/dompurify_tests.json'), 'utf8')
);

// ── Load zanitize WASM ─────────────────────────────────────────────────────

const zan = await loadZanitize(
  new URL('../wasm-out/zanitize.wasm', import.meta.url)
);
zan.init(); // default/strict config

// ── Instrument + sanitize ──────────────────────────────────────────────────

// Replace ALL alert(...) calls with alert('xss-N') for traceability.
// This includes alert in hrefs, event handlers, scripts, etc.
// Non-alert XSS (fetch, eval, etc.) are handled by the fetch override and
// by the general absence of unexpected network activity.
function instrument(payload, i) {
  return payload.replace(/alert\s*\([^)]*\)/g, `alert('xss-${i}')`);
}

const results = [];
let sanitizeErrors = 0;
const staticFailures = []; // survivors detected by static analysis

for (let i = 0; i < tests.length; i++) {
  const { payload } = tests[i];
  const instrumented = instrument(payload, i);
  const sanitized = zan.sanitizeFragment(instrumented);
  if (sanitized === null) {
    console.warn(`  [${i}] sanitize returned null — skipping`);
    sanitizeErrors++;
    results.push({ i, payload, sanitized: '<!-- sanitize error -->' });
  } else {
    results.push({ i, payload, sanitized });
    // ── Static analysis: look for dangerous survivors ──
    // A real event handler looks like: whitespace/< + tag stuff + onX= (not inside quotes)
    // Strategy: tokenize the HTML by splitting on tags, then check each tag's attributes.
    const issues = staticAnalyze(sanitized, i);
    if (issues.length) staticFailures.push(...issues);
  }
}

if (staticFailures.length > 0) {
  console.warn(`\nStatic analysis found ${staticFailures.length} potential issue(s):`);
  for (const { i, kind, detail } of staticFailures) {
    console.warn(`  #${i} [${kind}] ${detail}`);
  }
} else {
  console.log('Static analysis: no obvious XSS survivors detected.');
}
console.log(`Sanitized ${results.length} tests (${sanitizeErrors} errors)`);

/**
 * Tokenize HTML tags and check for dangerous attributes/elements.
 * Returns an array of { i, kind, detail } issues found.
 */
function staticAnalyze(html, testIdx) {
  const issues = [];
  // Walk all HTML tags (opening tags) using a simple state machine.
  // We look for <tagname attr=val> sequences and flag:
  //   1. on* event handler attributes
  //   2. javascript: URIs in href/src/action/formaction
  //   3. <script elements
  const tagRe = /<([a-zA-Z][^\s>\/]*)((?:[^>'"]*|'[^']*'|"[^"]*")*)\s*\/?>/g;
  let m;
  while ((m = tagRe.exec(html)) !== null) {
    const tagName = m[1].toLowerCase();
    const attrStr = m[2];

    if (tagName === 'script') {
      issues.push({ i: testIdx, kind: 'script', detail: `<script> element survived` });
      continue;
    }

    // Parse attributes: key=value (single/double/unquoted)
    const attrRe = /\s+([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]*)))?/g;
    let am;
    while ((am = attrRe.exec(attrStr)) !== null) {
      const attrName = am[1].toLowerCase();
      const attrVal  = (am[2] ?? am[3] ?? am[4] ?? '').toLowerCase().trim();

      if (/^on/.test(attrName)) {
        issues.push({ i: testIdx, kind: 'handler', detail: `${attrName}="${attrVal.slice(0,60)}"` });
      }
      if (['href','src','action','formaction','xlink:href'].includes(attrName)) {
        if (/^javascript\s*:/i.test(attrVal) || /^data\s*:[^,]*script/i.test(attrVal)) {
          issues.push({ i: testIdx, kind: 'uri', detail: `${attrName}="${attrVal.slice(0,60)}"` });
        }
      }
    }
  }
  return issues;
}

// ── Generate harness HTML ──────────────────────────────────────────────────

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, buildHarness(results), 'utf8');
console.log(`Written → ${outPath}`);

// ── HTML builder ──────────────────────────────────────────────────────────

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function buildHarness(results) {
  const total = results.length;

  // Each test: show a collapsible summary with the original payload,
  // then embed the sanitized fragment directly (NOT via innerHTML — the
  // fragment is baked into the static HTML so scripts that survive execute).
  const sections = results.map(({ i, payload, sanitized }) => {
    // Wrap the sanitized fragment in a container so we can dispatch events on it.
    // The fragment is embedded as raw HTML — intentionally, to catch surviving scripts.
    return `<section class="t" id="t${i}" data-i="${i}">` +
      `<details><summary><span class="badge" id="b${i}">?</span> #${i}</summary>` +
      `<pre class="src">${esc(payload)}</pre></details>` +
      `<div class="frag">${sanitized}</div>` +
      `</section>`;
  }).join('\n');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>zanitize XSS harness (${total} tests)</title>

<!--
  IMPORTANT: alert/fetch overrides MUST be in <head>, before the body is parsed.
  Any <script> tag that survived sanitization will run as the browser parses the
  body. Overriding window.alert here ensures those scripts are caught.
-->
<script>
(function () {
  var fired = [];
  window.__xss = fired;

  window.alert   = function (m) { fired.push(String(m)); };
  window.confirm = function ()  { return false; };
  window.prompt  = function ()  { return ''; };

  // Catch fetch-based exfiltration
  var _fetch = window.fetch;
  window.fetch = function (url) {
    fired.push('fetch:' + url);
    return typeof _fetch === 'function'
      ? _fetch.apply(this, arguments)
      : Promise.reject(new Error('fetch blocked by harness'));
  };

  // Catch XMLHttpRequest-based exfiltration
  var _XHR = window.XMLHttpRequest;
  if (_XHR) {
    window.XMLHttpRequest = function () {
      var xhr = new _XHR();
      var _open = xhr.open.bind(xhr);
      xhr.open = function (method, url) {
        fired.push('xhr:' + url);
        return _open.apply(this, arguments);
      };
      return xhr;
    };
  }
})();
</script>

<style>
* { box-sizing: border-box; }
body { font-family: system-ui, sans-serif; padding: 1rem; max-width: 980px; margin: 0 auto; }
h1   { margin-bottom: 0.5rem; }
#summary { padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; font-size: 1.1em; }
.pass { background: #d1f7d1; color: #1a5c1a; }
.fail { background: #fde0e0; color: #7a1a1a; }
.running { background: #fff3cd; color: #664d00; }
#fired-box { display: none; background: #fff3cd; border: 1px solid #f0c040; border-radius: 4px;
             padding: 0.75rem; margin-bottom: 1rem; }
#tests { margin-top: 0.5rem; }
.t    { border: 1px solid #e0e0e0; border-radius: 4px; margin: 0.25rem 0; padding: 0.25rem 0.5rem; }
.t.xss-fail { border-color: #dc3545; background: #fff0f0; }
.t.xss-pass { border-color: #28a745; }
pre.src { font-size: 0.72em; overflow-x: auto; background: #f8f8f8; padding: 0.4rem;
          margin: 0.25rem 0 0; border-radius: 3px; white-space: pre-wrap; word-break: break-all; }
.frag { font-size: 0.8em; color: #555; padding: 0.15rem 0.25rem; min-height: 0.5em; }
.badge { display: inline-block; font-size: 0.72em; padding: 1px 6px; border-radius: 8px;
         background: #ccc; color: #333; margin-right: 4px; font-weight: bold; }
.badge.ok   { background: #28a745; color: #fff; }
.badge.fail { background: #dc3545; color: #fff; }
details > summary { cursor: pointer; user-select: none; }
</style>
</head>
<body>
<h1>zanitize XSS harness</h1>
<div id="summary" class="running">⏳ Running ${total} tests…</div>
<div id="fired-box">
  <b>Fired events:</b>
  <pre id="fired-pre"></pre>
</div>

<div id="tests">
${sections}
</div>

<script>
// After the full page has loaded (all inline scripts and onerror/onload ran),
// dispatch synthetic interaction events to catch attribute-based handlers.
window.addEventListener('load', function () {
  var interactionEvents = ['click', 'mouseover', 'mouseenter', 'focus', 'input', 'keydown', 'pointerover'];

  document.querySelectorAll('#tests .frag *').forEach(function (el) {
    interactionEvents.forEach(function (ev) {
      if (el.hasAttribute('on' + ev)) {
        try { el.dispatchEvent(new Event(ev, { bubbles: true })); } catch (e) {}
      }
    });
  });

  // Allow async handlers (setTimeout 0 etc.) to settle before reporting
  setTimeout(function () {
    var fired = window.__xss;
    var summary = document.getElementById('summary');
    var firedBox = document.getElementById('fired-box');
    var firedPre = document.getElementById('fired-pre');

    // Tag per-test badges
    fired.forEach(function (msg) {
      var m = msg.match(/^xss-(\d+)$/);
      if (m) {
        var n = m[1];
        var badge = document.getElementById('b' + n);
        var section = document.getElementById('t' + n);
        if (badge)   { badge.textContent = 'FAIL'; badge.className = 'badge fail'; }
        if (section) { section.classList.add('xss-fail'); }
      }
    });

    // Mark passing tests
    for (var i = 0; i < ${total}; i++) {
      var badge = document.getElementById('b' + i);
      if (badge && badge.textContent === '?') {
        badge.textContent = 'ok';
        badge.className = 'badge ok';
        var sec = document.getElementById('t' + i);
        if (sec) sec.classList.add('xss-pass');
      }
    }

    if (fired.length === 0) {
      summary.textContent = '✅ ALL ${total} TESTS PASS — 0 XSS escaped';
      summary.className = 'pass';
    } else {
      var xssCount = fired.filter(function(m){ return /^xss-/.test(m); }).length;
      summary.textContent = '❌ ' + xssCount + ' XSS escape(s) across ${total} tests (' +
        fired.length + ' total event(s))';
      summary.className = 'fail';
      firedBox.style.display = 'block';
      firedPre.textContent = JSON.stringify(fired, null, 2);
    }
  }, 200);
});
</script>
</body>
</html>`;
}
