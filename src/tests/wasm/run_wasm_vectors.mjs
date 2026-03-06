#!/usr/bin/env node
/**
 * run_wasm_vectors.mjs — Run OWASP/PortSwigger/CSS/HTML5 test vectors
 * against the zanitize WASM module.
 *
 * Test data: tests/input/owasp_vectors.json  (extracted from
 *            src/modules/sanitizer_test_vectors.zig via extract_zig_vectors.mjs)
 *
 * Each case uses `should_not_contain` / `should_contain` checks
 * (case-insensitive substring search) — same semantics as the Zig runner,
 * but exercising the WASM code path.
 *
 * Usage:
 *   node tests/run_wasm_vectors.mjs [--suite SUITE_NAME] [--filter SUBSTR]
 *
 * Examples:
 *   node tests/run_wasm_vectors.mjs
 *   node tests/run_wasm_vectors.mjs --suite PORTSWIGGER_EVENT_HANDLERS
 *   node tests/run_wasm_vectors.mjs --filter "onerror"
 */

import { loadZanitize } from '../wasm-out/zanitize.js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const __dir = dirname(fileURLToPath(import.meta.url));

// ── CLI args ───────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const suiteFilter  = args[args.indexOf('--suite')  + 1] ?? null;
const nameFilter   = args[args.indexOf('--filter') + 1] ?? null;

// ── Load WASM ──────────────────────────────────────────────────────────────
const zan = await loadZanitize(
  new URL('../wasm-out/zanitize.wasm', import.meta.url)
);
zan.init(); // default/strict config

// ── Load vectors ───────────────────────────────────────────────────────────
const suites = JSON.parse(
  readFileSync(resolve(__dir, 'input/owasp_vectors.json'), 'utf8')
);

// ── Helpers ────────────────────────────────────────────────────────────────
function containsCI(haystack, needle) {
  return haystack.toLowerCase().includes(needle.toLowerCase());
}

const RESET  = '\x1b[0m';
const RED    = '\x1b[31m';
const GREEN  = '\x1b[32m';
const YELLOW = '\x1b[33m';
const BOLD   = '\x1b[1m';
const DIM    = '\x1b[2m';

// ── Run ────────────────────────────────────────────────────────────────────
let total = 0, passed = 0, failed = 0, skipped = 0;
const failures = [];

for (const { suite, cases } of suites) {
  if (suiteFilter && suite !== suiteFilter) continue;

  const suitePassed = [], suiteFailed = [];

  for (const { name, threat_html, should_not_contain, should_contain } of cases) {
    if (nameFilter && !containsCI(name, nameFilter) && !containsCI(threat_html, nameFilter)) continue;
    total++;

    const out = zan.sanitizeFragment(threat_html);
    if (out === null) {
      skipped++;
      console.log(`${YELLOW}  SKIP${RESET} ${name}`);
      continue;
    }

    let ok = true;
    const reasons = [];

    // should_not_contain — forbidden patterns
    for (const pattern of should_not_contain) {
      if (containsCI(out, pattern)) {
        ok = false;
        reasons.push(`forbidden pattern found: "${pattern}"`);
      }
    }

    // should_contain — required patterns
    if (should_contain) {
      for (const pattern of should_contain) {
        if (!containsCI(out, pattern)) {
          ok = false;
          reasons.push(`required pattern missing: "${pattern}"`);
        }
      }
    }

    if (ok) {
      passed++;
      suitePassed.push(name);
    } else {
      failed++;
      suiteFailed.push({ name, threat_html, out, reasons });
      failures.push({ suite, name, threat_html, out, reasons });
    }
  }

  // Per-suite summary
  const suiteTotal = suitePassed.length + suiteFailed.length;
  if (suiteTotal === 0) continue;

  const suiteMark = suiteFailed.length === 0 ? `${GREEN}✓${RESET}` : `${RED}✗${RESET}`;
  console.log(`\n${BOLD}${suiteMark} ${suite}${RESET} ${DIM}(${suitePassed.length}/${suiteTotal})${RESET}`);

  for (const { name, threat_html, out, reasons } of suiteFailed) {
    console.log(`  ${RED}FAIL${RESET} ${name}`);
    for (const r of reasons) {
      console.log(`       ${RED}↳${RESET} ${r}`);
    }
    console.log(`       ${DIM}in:  ${threat_html.slice(0, 100)}${RESET}`);
    console.log(`       ${DIM}out: ${out.slice(0, 150)}${RESET}`);
  }
}

// ── Final summary ──────────────────────────────────────────────────────────
console.log('\n' + '─'.repeat(60));
if (failed === 0) {
  console.log(`${GREEN}${BOLD}ALL PASS${RESET}  ${passed}/${total} tests passed${skipped ? ` (${skipped} skipped)` : ''}`);
} else {
  console.log(`${RED}${BOLD}FAILURES: ${failed}${RESET}  ${passed} passed, ${failed} failed` +
    (skipped ? `, ${skipped} skipped` : '') + ` of ${total} total`);
  process.exitCode = 1;
}
