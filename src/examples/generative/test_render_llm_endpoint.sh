#!/usr/bin/env bash
# test_render_llm_endpoint.sh
#
# Smoke test for the GET /render_llm HTTP endpoint.
#
# The endpoint streams an Ollama prompt directly into the headless DOM and
# returns the painted result as a binary image — no JS pipeline required.
# Designed to be used as an <img src> in plain HTML:
#
#   <img src="http://localhost:9984/render_llm?prompt=3+metric+cards&model=llama3.1">
#
# Prerequisites:
#   - zxp serve running: ./zig-out/bin/zxp serve .
#   - Ollama already running on localhost:11434

set -euo pipefail

BASE="http://localhost:9984"
OUT="/tmp/render_llm_smoke.png"

echo "→ GET /render_llm (png, 800px wide)"
curl -sf \
  "${BASE}/render_llm?prompt=3+metric+cards+Revenue+%2412k+Users+340+MRR+%244.2k&model=llama3.1&format=png&width=800" \
  -o "${OUT}"

SIZE=$(wc -c < "${OUT}")
echo "✓ ${SIZE} bytes → ${OUT}"

echo ""
echo "→ GET /render_llm (webp, custom width)"
OUT2="/tmp/render_llm_smoke.webp"
curl -sf \
  "${BASE}/render_llm?prompt=A+simple+dashboard+with+a+blue+header+and+two+stat+cards&model=llama3.1&format=webp&width=1200" \
  -o "${OUT2}"

SIZE2=$(wc -c < "${OUT2}")
echo "✓ ${SIZE2} bytes → ${OUT2}"
