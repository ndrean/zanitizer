#!/usr/bin/env bash
# smoke_serve.sh
#
# Smoke tests for the zxp dev-server endpoints — no Ollama required.
#
# Covers:
#   /health       — sanity
#   /run          — markdownToHTML, toMarkdown, MD round-trip
#   /stream       — basic HTML, CSS, script-driven DOM mutation,
#                   markdown conversion inside a script
#   /mcp          — initialize, tools/list, render_html (PNG), run_script (text + image)
#
# Prerequisites:
#   ./zig-out/bin/zxp serve .
#
# Usage:
#   bash src/examples/generative/smoke_serve.sh

set -euo pipefail

BASE="http://localhost:9984"
PASS=0
FAIL=0

# ── helpers ─────────────────────────────────────────────────────────────────

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗\033[0m %s\n' "$*"; }

# assert_contains <label> <needle> <body>
assert_contains() {
  local label="$1" needle="$2" body="$3"
  if echo "$body" | grep -qF "$needle"; then
    green "$label (contains: $needle)"
    PASS=$((PASS + 1))
  else
    red "$label (missing: $needle)"
    echo "  body: ${body:0:300}"
    FAIL=$((FAIL + 1))
  fi
}

# assert_not_empty <label> <body>
assert_not_empty() {
  local label="$1" body="$2"
  if [ -n "$body" ]; then
    green "$label (non-empty)"
    PASS=$((PASS + 1))
  else
    red "$label (empty response)"
    FAIL=$((FAIL + 1))
  fi
}

# ── /health ──────────────────────────────────────────────────────────────────

echo ""
echo "═══ /health ════════════════════════════════════════════════════════════"
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/health")
if [ "$STATUS" = "200" ]; then
  green "/health → 200"
  PASS=$((PASS + 1))
else
  red "/health → $STATUS (expected 200)"
  FAIL=$((FAIL + 1))
fi

# ── /run — markdownToHTML ────────────────────────────────────────────────────

echo ""
echo "═══ /run — markdownToHTML ══════════════════════════════════════════════"

MD_SCRIPT='
const md = `# Smoke Test

**bold**, _italic_, ~~strike~~.

| Col A | Col B |
|-------|-------|
| foo   | bar   |

- [x] md4c GFM
- [ ] not done
`;
const html = zxp.markdownToHTML(md);
zxp.write(html);
'

OUT=$(curl -sf -X POST "$BASE/run" --data-binary "$MD_SCRIPT")
assert_contains "markdownToHTML: h1"       "<h1>"          "$OUT"
assert_contains "markdownToHTML: strong"   "<strong>"      "$OUT"
assert_contains "markdownToHTML: em"       "<em>"          "$OUT"
assert_contains "markdownToHTML: del"      "<del>"         "$OUT"
assert_contains "markdownToHTML: table"    "<table>"       "$OUT"
assert_contains "markdownToHTML: taskbox"  'type="checkbox"' "$OUT"

# ── /run — toMarkdown ────────────────────────────────────────────────────────

echo ""
echo "═══ /run — toMarkdown (DOM → MD) ═══════════════════════════════════════"

TOMD_SCRIPT='
zxp.loadHTML(`<html><body>
  <h1>Hello Markdown</h1>
  <p>A paragraph with <strong>bold</strong> and <em>italic</em>.</p>
  <ul><li>Item A</li><li>Item B</li></ul>
  <table>
    <thead><tr><th>Name</th><th>Value</th></tr></thead>
    <tbody><tr><td>foo</td><td>bar</td></tr></tbody>
  </table>
</body></html>`);
const md = zxp.toMarkdown(document.body);
zxp.write(md);
'

OUT=$(curl -sf -X POST "$BASE/run" --data-binary "$TOMD_SCRIPT")
assert_contains "toMarkdown: h1 atx"    "# Hello Markdown" "$OUT"
assert_contains "toMarkdown: strong"    "**bold**"         "$OUT"
assert_contains "toMarkdown: em"        "_italic_"         "$OUT"
assert_contains "toMarkdown: list item" "Item A"           "$OUT"

# ── /run — MD round-trip (MD → HTML → DOM → MD) ──────────────────────────────

echo ""
echo "═══ /run — Markdown round-trip ═════════════════════════════════════════"

ROUNDTRIP_SCRIPT='
const md1 = `# Round Trip\n\n**bold** and _italic_ text.\n\n- alpha\n- beta\n`;
const html = zxp.markdownToHTML(md1);
zxp.loadHTML("<html><body>" + html + "</body></html>");
const md2 = zxp.toMarkdown(document.body);
zxp.write(md2);
'

OUT=$(curl -sf -X POST "$BASE/run" --data-binary "$ROUNDTRIP_SCRIPT")
assert_contains "round-trip: heading"    "Round Trip"  "$OUT"
assert_contains "round-trip: bold"       "**bold**"    "$OUT"
assert_contains "round-trip: list bullet" "alpha"       "$OUT"

# ── /run — markdownToHTML → paintDOM (PNG bytes) ──────────────────────────────

echo ""
echo "═══ /run — markdownToHTML → paintDOM → PNG ══════════════════════════════"

PAINT_SCRIPT='
function run() {
  const md = "# Rendered Markdown\n\n**Bold** text and a list:\n\n- alpha\n- beta\n";
  const html = zxp.markdownToHTML(md);
  const page = "<html><head><style>body{font-family:sans-serif;padding:24px;max-width:640px}</style></head><body>" + html + "</body></html>";
  zxp.loadHTML(page);
  return zxp.encode(zxp.paintDOM(document.body, 600), "png");
}
run();
'

PNG=$(curl -sf -X POST "$BASE/run" --data-binary "$PAINT_SCRIPT" -o /tmp/md_painted.png -w "%{http_code}")
if [ "$PNG" = "200" ] && [ -s /tmp/md_painted.png ]; then
  MAGIC=$(xxd -l 4 /tmp/md_painted.png | head -1)
  if echo "$MAGIC" | grep -q "8950"; then
    green "paintDOM PNG: valid PNG magic bytes → /tmp/md_painted.png"
    PASS=$((PASS + 1))
  else
    red "paintDOM PNG: bad magic bytes"
    FAIL=$((FAIL + 1))
  fi
else
  red "paintDOM PNG: HTTP $PNG or empty file"
  FAIL=$((FAIL + 1))
fi

# ── /stream — basic HTML passthrough ─────────────────────────────────────────

echo ""
echo "═══ /stream — basic HTML ════════════════════════════════════════════════"

HTML_BASIC='<html><head><title>Stream Test</title></head><body><p id="hello">Hello Stream</p></body></html>'
OUT=$(curl -sf -X POST "$BASE/stream" --data-binary "$HTML_BASIC" -H "Content-Type: text/html")
assert_contains "/stream basic: p tag"    "<p"           "$OUT"
assert_contains "/stream basic: content"  "Hello Stream" "$OUT"

# ── /stream — CSS preserved ───────────────────────────────────────────────────

echo ""
echo "═══ /stream — CSS passthrough ═══════════════════════════════════════════"

HTML_CSS='<html><head><style>body{color:red;font-size:16px}</style></head><body><p>Styled</p></body></html>'
OUT=$(curl -sf -X POST "$BASE/stream" --data-binary "$HTML_CSS")
assert_contains "/stream CSS: style tag"  "<style" "$OUT"
assert_contains "/stream CSS: content"    "Styled"  "$OUT"

# ── /stream — script modifies DOM ────────────────────────────────────────────

echo ""
echo "═══ /stream — script-driven DOM mutation ════════════════════════════════"

HTML_SCRIPT='<html><body>
  <div id="target">original</div>
  <script>document.getElementById("target").textContent = "injected";</script>
</body></html>'

OUT=$(curl -sf -X POST "$BASE/stream" --data-binary "$HTML_SCRIPT")
assert_contains "/stream script DOM: injected text" "injected" "$OUT"

# ── /stream — markdownToHTML inside a script ─────────────────────────────────

echo ""
echo "═══ /stream — markdownToHTML inside inline script ═══════════════════════"

# The script calls zxp.markdownToHTML and injects the result into the DOM.
# The /stream endpoint then serialises document.documentElement.outerHTML.
HTML_MD_SCRIPT='<html><body>
  <div id="md-out"></div>
  <script>
    var md = "# Streamed MD\n\n**bold** and _italic_.\n\n- item one\n- item two\n";
    document.getElementById("md-out").innerHTML = zxp.markdownToHTML(md);
  </script>
</body></html>'

OUT=$(curl -sf -X POST "$BASE/stream" --data-binary "$HTML_MD_SCRIPT")
assert_contains "/stream md-in-script: h1"     "<h1>"          "$OUT"
assert_contains "/stream md-in-script: strong" "<strong>"      "$OUT"
assert_contains "/stream md-in-script: list"   "<li>"          "$OUT"

# ── /stream — toMarkdown inside a script ─────────────────────────────────────

echo ""
echo "═══ /stream — toMarkdown inside inline script ═══════════════════════════"

# Script calls toMarkdown and zxp.write — output arrives as HTTP chunks before
# the body; the final body is the serialised document.  We check for the MD
# text in either part of the response.
HTML_TOMD_SCRIPT='<html><body>
  <article>
    <h2>Turndown Test</h2>
    <p>A <strong>bold</strong> paragraph.</p>
  </article>
  <script>
    var md = zxp.toMarkdown(document.querySelector("article"));
    zxp.write(md);
  </script>
</body></html>'

OUT=$(curl -sf -X POST "$BASE/stream" --data-binary "$HTML_TOMD_SCRIPT")
assert_contains "/stream toMarkdown: heading" "Turndown Test" "$OUT"
assert_contains "/stream toMarkdown: bold"    "bold"          "$OUT"

# ── /mcp — JSON-RPC 2.0 ──────────────────────────────────────────────────────

echo ""
echo "═══ /mcp — JSON-RPC 2.0 ════════════════════════════════════════════════"

MCP_INIT=$(curl -sf -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')
assert_contains "/mcp initialize: version"    '"protocolVersion"' "$MCP_INIT"
assert_contains "/mcp initialize: serverInfo" '"zexplorer"'       "$MCP_INIT"

MCP_LIST=$(curl -sf -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
assert_contains "/mcp tools/list: render_html"     '"render_html"'     "$MCP_LIST"
assert_contains "/mcp tools/list: render_markdown" '"render_markdown"' "$MCP_LIST"
assert_contains "/mcp tools/list: render_url"      '"render_url"'      "$MCP_LIST"
assert_contains "/mcp tools/list: run_script"      '"run_script"'      "$MCP_LIST"

MCP_HTML=$(curl -sf -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"render_html","arguments":{"html":"<h1>MCP</h1>","width":200}}}')
assert_contains "/mcp render_html: image type" '"type":"image"' "$MCP_HTML"
assert_contains "/mcp render_html: png mime"   '"image/png"'    "$MCP_HTML"

# Verify the base64 data decodes to a valid PNG
MCP_PNG_B64=$(echo "$MCP_HTML" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['content'][0]['data'])" 2>/dev/null)
if [ -n "$MCP_PNG_B64" ]; then
  echo "$MCP_PNG_B64" | base64 -d > /tmp/mcp_smoke.png 2>/dev/null
  if xxd -l 4 /tmp/mcp_smoke.png 2>/dev/null | grep -q "8950"; then
    green "/mcp render_html: valid PNG magic bytes"
    PASS=$((PASS + 1))
  else
    red "/mcp render_html: invalid PNG bytes"
    FAIL=$((FAIL + 1))
  fi
else
  red "/mcp render_html: could not extract base64 data"
  FAIL=$((FAIL + 1))
fi

MCP_SCRIPT=$(curl -sf -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"run_script","arguments":{"script":"40 + 2"}}}')
assert_contains "/mcp run_script: text type"  '"type":"text"' "$MCP_SCRIPT"
assert_contains "/mcp run_script: value 42"   '"42"'          "$MCP_SCRIPT"

MCP_IMG=$(curl -sf -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"run_script","arguments":{"script":"zxp.loadHTML(\"<h1>Hi</h1>\"); zxp.encode(zxp.paintDOM(document.body,200),\"png\")"}}}')
assert_contains "/mcp run_script image: image type" '"type":"image"' "$MCP_IMG"
assert_contains "/mcp run_script image: png mime"   '"image/png"'    "$MCP_IMG"

MCP_ERR=$(curl -sf -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":6,"method":"unknown_method"}')
assert_contains "/mcp unknown method: error code" '"code":-32601' "$MCP_ERR"

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  red "$FAIL test(s) failed"
  exit 1
else
  green "All tests passed"
fi
