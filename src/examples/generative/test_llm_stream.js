// test_llm_stream.js
//
// Smoke test for zxp.llmStream — the single-parse streaming path.
//
// Unlike llmHTML, tokens are fed directly to lexbor's chunk parser as they
// arrive from Ollama; no HTML string is accumulated, no second parse pass.
//
// Run:
//   ./zig-out/bin/zxp run src/examples/generative/test_llm_stream.js -o /tmp/llm_stream.png

function run() {
  zxp.llmStream({
    model: "llama3.1",
    prompt:
      "Design 3 metric cards in a row using flexbox: Revenue $12k, Users 340, Uptime 99.9%. " +
      "White background, each card a different accent color, rounded corners.",
  });

  const img = zxp.paintDOM(document.body, 800);
  return zxp.encode(img, "png");
  // zxp.save(img, "src/examples/generative/llm_stream.png");
}
run();
