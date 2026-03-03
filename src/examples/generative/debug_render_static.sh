#!/bin/bash
# debug_render_static.sh
#
# Hits the same endpoint and path as the static <img> in render_llm_demo.html.
# Saves to /tmp/debug_static.png so you can inspect it.
#
# Usage: bash src/examples/generative/debug_render_static.sh

PROMPT="3 metric cards: Revenue \$12k, Users 340, MRR \$4.2k. Clean white cards, blue accent color."

echo "[debug] fetching /render_llm prompt='${PROMPT}'"
curl -s --get http://localhost:9984/render_llm \
  --data-urlencode "prompt=${PROMPT}" \
  -d "width=600&format=png" \
  -o /tmp/debug_static.png
echo "[debug] saved to /tmp/debug_static.png"

# Check it's actually a PNG
if xxd -l 4 /tmp/debug_static.png | grep -q "8950 4e47"; then
  echo "[debug] valid PNG"
  kitty +kitten icat /tmp/debug_static.png 2>/dev/null || echo "(kitty not available — open /tmp/debug_static.png manually)"
else
  echo "[debug] NOT a PNG — first bytes:"
  xxd -l 32 /tmp/debug_static.png
fi
