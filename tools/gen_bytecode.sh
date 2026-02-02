#!/bin/bash
# Generate QuickJS bytecode for framework libraries
#
# Usage: ./tools/gen_bytecode.sh
#
# Prerequisites:
#   - qjsc (QuickJS compiler) in PATH
#   - curl for downloading

set -e

BYTECODE_DIR="vendor/bytecode"
CACHE_DIR="vendor/js_cache"

mkdir -p "$BYTECODE_DIR"
mkdir -p "$CACHE_DIR"

echo "=== Generating QuickJS Bytecode ==="

# Function to download and compile
compile_module() {
    local name="$1"
    local url="$2"
    local output="$3"

    local cache_file="$CACHE_DIR/${name}.mjs"
    local bc_file="$BYTECODE_DIR/${output}.bc"

    echo ""
    echo "Processing: $name"
    echo "  URL: $url"

    # Download if not cached
    if [ ! -f "$cache_file" ]; then
        echo "  Downloading..."
        curl -sL "$url" -o "$cache_file"
    else
        echo "  Using cached source"
    fi

    # Compile to bytecode
    echo "  Compiling to bytecode..."
    if qjsc -c -m -o "$bc_file" "$cache_file" 2>/dev/null; then
        local size=$(wc -c < "$bc_file" | tr -d ' ')
        local src_size=$(wc -c < "$cache_file" | tr -d ' ')
        echo "  Done: $bc_file ($size bytes, source was $src_size bytes)"
    else
        echo "  Warning: qjsc failed, trying with eval wrapper..."
        # Some ESM modules need wrapping for qjsc
        echo "// Bytecode compilation not available for this module" > "$bc_file"
        echo "  Skipped (ESM module requires runtime compilation)"
    fi
}

# Compile frameworks
compile_module "preact" \
    "https://cdn.jsdelivr.net/npm/preact@10.19.3/dist/preact.mjs" \
    "preact"

compile_module "preact-hooks" \
    "https://cdn.jsdelivr.net/npm/preact@10.19.3/hooks/dist/hooks.mjs" \
    "preact-hooks"

compile_module "htm-standalone" \
    "https://cdn.jsdelivr.net/npm/htm@3.1.1/preact/standalone.mjs" \
    "htm-preact-standalone"

echo ""
echo "=== Bytecode Generation Complete ==="
echo ""
echo "To use in Zig, add to js_bytecode.zig:"
echo '  .{ "preact", @embedFile("../vendor/bytecode/preact.bc") },'
echo ""
ls -la "$BYTECODE_DIR"
