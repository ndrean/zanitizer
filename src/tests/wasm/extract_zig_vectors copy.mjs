#!/usr/bin/env node
/**
 * One-time extractor: reads src/modules/sanitizer_test_vectors.zig
 * and writes tests/input/owasp_vectors.json.
 *
 * Usage: node tests/extract_zig_vectors.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const __dir = dirname(fileURLToPath(import.meta.url));
const zigPath  = resolve(__dir, '../src/modules/sanitizer_test_vectors.zig');
const outPath  = resolve(__dir, 'input/owasp_vectors.json');

const src = readFileSync(zigPath, 'utf8');

// ── Suite boundaries ───────────────────────────────────────────────────────
// Each suite is a `const NAME = [_]TestCase{ ... };` block.
const suitePattern = /const\s+([\w]+)\s*=\s*\[_\]TestCase\{([\s\S]*?)\};\n/g;

// ── TestCase block ─────────────────────────────────────────────────────────
// Each test case is a `.{ .name=..., .threat_html=..., ... }` block.
// We use a stateful parser rather than a single regex to handle nested braces.
function extractCases(suiteBody) {
  const cases = [];
  let i = 0;

  while (i < suiteBody.length) {
    // Find the start of a test case: `.{`
    const start = suiteBody.indexOf('.{\n', i);
    if (start === -1) break;

    // Walk to find the matching `}` (counting brace depth)
    let depth = 0;
    let j = start;
    while (j < suiteBody.length) {
      if (suiteBody[j] === '{') depth++;
      else if (suiteBody[j] === '}') {
        depth--;
        if (depth === 0) break;
      }
      j++;
    }

    const block = suiteBody.slice(start, j + 1);
    const tc = parseTestCase(block);
    if (tc) cases.push(tc);
    i = j + 1;
  }
  return cases;
}

// ── Parse a single .{...} block ────────────────────────────────────────────
function parseTestCase(block) {
  const name          = extractZigString(block, '.name');
  const threat_html   = extractZigString(block, '.threat_html');
  const shouldNot     = extractStringList(block, '.should_not_contain');
  const shouldHave    = extractStringList(block, '.should_contain');

  if (!name || !threat_html || !shouldNot) return null;

  const tc = { name, threat_html, should_not_contain: shouldNot };
  if (shouldHave !== null) tc.should_contain = shouldHave;
  return tc;
}

// Extract the value of a Zig string field: .field_name = "..."
// Handles escape sequences compatible with JSON (\" \\ \n \t \r \0)
// Also handles Zig-specific \xHH and \u{HHHH}
function extractZigString(block, field) {
  // Match: .field_name = "..."  where the string ends at an unescaped "
  const re = new RegExp(field.replace('.', '\\.') + '\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"');
  const m = re.exec(block);
  if (!m) return null;
  return zigStringToJs(m[1]);
}

// Convert Zig escape sequences to their character equivalents
function zigStringToJs(s) {
  return s
    .replace(/\\x([0-9a-fA-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/\\n/g, '\n')
    .replace(/\\r/g, '\r')
    .replace(/\\t/g, '\t')
    .replace(/\\0/g, '\0')
    .replace(/\\\\/g, '\\')
    .replace(/\\"/g, '"');
}

// Extract &.{"a","b",...} — an array of strings
function extractStringList(block, field) {
  const re = new RegExp(field.replace('.', '\\.') + '\\s*=\\s*&\\.\\{([^}]*)\\}');
  const m = re.exec(block);
  if (!m) return null;

  const inner = m[1].trim();
  if (!inner) return [];

  // Split on `,` outside of strings
  const items = [];
  let inStr = false, escape = false, cur = '';
  for (const ch of inner) {
    if (escape)     { cur += ch; escape = false; continue; }
    if (ch === '\\') { escape = true; cur += ch; continue; }
    if (ch === '"')  { inStr = !inStr; cur += ch; continue; }
    if (!inStr && ch === ',') {
      const trimmed = cur.trim();
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        items.push(zigStringToJs(trimmed.slice(1, -1)));
      }
      cur = '';
      continue;
    }
    cur += ch;
  }
  const trimmed = cur.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    items.push(zigStringToJs(trimmed.slice(1, -1)));
  }

  return items;
}

// ── Walk all suites ────────────────────────────────────────────────────────
const suites = [];
let m;
while ((m = suitePattern.exec(src)) !== null) {
  const suiteName = m[1];
  // Skip non-TestCase arrays (H5SC_DANGEROUS_TAGS etc.)
  if (suiteName === 'H5SC_DANGEROUS_TAGS') continue;

  const cases = extractCases(m[2]);
  if (cases.length === 0) continue;

  suites.push({ suite: suiteName, cases });
  console.log(`  ${suiteName}: ${cases.length} cases`);
}

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(suites, null, 2), 'utf8');
const total = suites.reduce((s, x) => s + x.cases.length, 0);
console.log(`\nExtracted ${total} cases across ${suites.length} suites → ${outPath}`);
