#!/usr/bin/env bash
# Smoke tests for zanitize CLI.
# Usage: bash src/examples/smoke.sh [path/to/zanitize]
# Defaults to ./zig-out/bin/zan if not given.

set -euo pipefail

BIN="${1:-./zig-out/bin/zan}"
PASS=0
FAIL=0

check() {
    local label="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -qF "$expected"; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label"
        echo "        expected to find: $expected"
        echo "        got: $actual"
        FAIL=$((FAIL+1))
    fi
}

absent() {
    local label="$1" banned="$2" actual="$3"
    if echo "$actual" | grep -qF "$banned"; then
        echo "  FAIL  $label"
        echo "        should NOT contain: $banned"
        echo "        got: $actual"
        FAIL=$((FAIL+1))
    else
        echo "  PASS  $label"
        PASS=$((PASS+1))
    fi
}

echo "zanitize smoke tests — $BIN"
echo "---"

# XSS baseline
out=$(echo '<script>alert(1)</script><p>Hello</p>' | "$BIN")
absent "XSS: script removed"         "<script>"  "$out"
check  "XSS: safe content kept"       "<p>Hello"  "$out"

# Event handler stripped
out=$(echo '<a onclick="evil()" href="https://ok.com">link</a>' | "$BIN")
absent "attr: onclick removed"        "onclick"   "$out"
check  "attr: href kept"              'href="https://ok.com"' "$out"

# removeElements via --config-file
tmp=$(mktemp /tmp/zanitize-smoke-XXXX.json)
echo '{"removeElements":["b"]}' > "$tmp"
out=$(echo '<p>Hello <b>world</b></p>' | "$BIN" --config-file "$tmp")
absent "removeElements: <b> gone"     "<b>"       "$out"
check  "removeElements: <p> kept"     "<p>"       "$out"
rm -f "$tmp"

# removeElements via inline --config
out=$(echo '<p>Hello <b>world</b></p>' | "$BIN" --config '{"removeElements":["b"]}')
absent "inline config: <b> gone"      "<b>"       "$out"
check  "inline config: <p> kept"      "<p>"       "$out"

# replaceWithChildrenElements (unwrap)
out=$(echo '<p>Hello <b>world</b></p>' | "$BIN" --config '{"replaceWithChildrenElements":["b"]}')
absent "unwrap: <b> tag gone"         "<b>"       "$out"
check  "unwrap: text preserved"       "Hello world" "$out"

# replaceWithChildrenElements — nested
out=$(echo '<b><i>bold italic</i></b>' | "$BIN" --config '{"replaceWithChildrenElements":["b","i"]}')
absent "unwrap nested: <b> gone"      "<b>"       "$out"
absent "unwrap nested: <i> gone"      "<i>"       "$out"
check  "unwrap nested: text kept"     "bold italic" "$out"

# elements allowlist — non-listed element unwrapped
out=$(echo '<p class="x" onclick="evil()">Hello <b>world</b></p>' | "$BIN" --config '{"elements":[{"name":"p","attributes":["class"]}]}')
check  "elements allowlist: <p> kept"         "<p "       "$out"
check  "elements allowlist: class attr kept"  'class="x"' "$out"
absent "elements allowlist: onclick stripped" "onclick"   "$out"
absent "elements allowlist: <b> tag stripped" "<b>"       "$out"
check  "elements allowlist: b text kept"      "world"     "$out"

# sanitizeInlineStyles: false keeps style=""
out=$(echo '<p style="color:red">text</p>' | "$BIN" --config '{"sanitizeInlineStyles":false}')
check  "sanitizeInlineStyles off: style kept" 'style="color:red"' "$out"

# sanitizeInlineStyles: true (default) strips dangerous CSS
out=$(echo '<p style="expression(alert(1))">text</p>' | "$BIN")
absent "sanitize CSS: expression() stripped" "expression" "$out"

# Preset: strict
out=$(echo '<b>text</b><a href="http://x.com">link</a>' | "$BIN" --preset strict)
check  "preset strict: <b> kept"    "<b>"              "$out"
check  "preset strict: <a> kept"    '<a href="http://' "$out"

# Markdown flag
out=$(printf '# Hello\n**world**\n' | "$BIN" --md)
check  "markdown: h1 rendered"     "<h1>Hello</h1>"   "$out"
check  "markdown: strong rendered" "<strong>world</strong>" "$out"

# Output to file
tmp=$(mktemp /tmp/zanitize-smoke-XXXX.html)
echo '<script>x</script><p>ok</p>' | "$BIN" -o "$tmp"
out=$(cat "$tmp")
rm -f "$tmp"
absent "file output: no script"    "<script>"  "$out"
check  "file output: p present"    "<p>ok</p>" "$out"

# Stdin dash
out=$(echo '<em>hi</em>' | "$BIN" -)
check  "stdin -: em kept" "<em>hi</em>" "$out"

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
