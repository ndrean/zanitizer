// debug_stream_html.js
//
// Tests the STREAMING path (same as /render_llm GET endpoint):
// zxp.llmStream → DOM built live via lexbor chunk parser.
//
// Returns diagnostic info + full document HTML via outerHTML
// (body.innerHTML has serialization limitations; outerHTML is known-good).
//
// Usage:
//   curl -s -X POST http://localhost:9984/run \
//     --data-binary @src/examples/generative/debug_stream_html.js

const PROMPT   = "3 metric cards: Revenue $12k, Users 340, MRR $4.2k. Clean white cards, blue accent color.";
const MODEL    = "qwen2.5-coder:7b";
const BASE_URL = "http://localhost:11434";

async function run() {
  console.log("[debug] streaming llm into DOM, model:", MODEL);
  zxp.llmStream({ model: MODEL, prompt: PROMPT, base_url: BASE_URL });

  const divCount  = document.querySelectorAll("div").length;
  const spanCount = document.querySelectorAll("span").length;
  console.log("[debug] stream done — divs:", divCount, " spans:", spanCount);
  console.log("[debug] body.children.length:", document.body.children.length);

  // outerHTML is reliably implemented; body.innerHTML has serialization gaps
  return document.documentElement.outerHTML;
}

run();
