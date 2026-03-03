// test_llm_demo.js
//
// Programmatic automation of render_llm_demo.html:
//   1. Loads the page with scripts enabled
//   2. Polls #result getAttribute("src") until the page script sets it to a
//      data URI. Uses getAttribute (C-level attribute) rather than the JS
//      property because getElementById returns a NEW JS wrapper each call —
//      Object.defineProperty on our wrapper never intercepts the page script's
//      `result.src = data:...` which goes through the prototype reflectedAttrSetter
//      and updates the C-level attribute directly.
//   3. Fetches the static <img> src (HTTP URL → data URI) so the compositor
//      can paint it. Both LLM calls are kicked off in parallel.
//   4. Dispatches "submit" on the form
//   5. Awaits both promises (static img + dynamic result)
//   6. Returns a compositor screenshot
//
// Usage:
//   curl -s -X POST http://localhost:9984/run \
//     --data-binary @src/examples/generative/test_llm_demo.js \
//     -o /tmp/render_llm_demo.png

async function fetchToDataUri(url) {
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`fetch ${url}: HTTP ${resp.status}`);
  const buf  = await resp.arrayBuffer();
  const mime = (resp.headers.get("content-type") || "image/png").split(";")[0].trim();
  return zxp.arrayBufferToBase64DataUri(buf, mime);
}

async function run() {
  // ── 1. Load the demo page with its <script> running ──────────────────────
  const pageHtml = new TextDecoder().decode(
    zxp.fs.readFileSync("src/examples/generative/render_llm_demo.html")
  );
  __native_loadPage(pageHtml, { execute_scripts: true, load_stylesheets: false });

  // ── 2. Watch #result via getAttribute polling ─────────────────────────────
  //    The page script's submit handler does: result.src = `data:${mime};base64,${data}`
  //    This calls the HTMLElement prototype's reflectedAttrSetter → setAttribute on the
  //    C-level lexbor element. Polling getAttribute('src') on ANY JS wrapper of that
  //    element sees the update because all wrappers share the same C node.
  const resultEl = document.getElementById("result");
  const imgLoaded = new Promise((resolve, reject) => {
    let _poll, _guard;
    function check() {
      const src = resultEl.getAttribute("src") || "";
      if (src.startsWith("data:")) {
        console.log("[imgLoaded test] IMG SRC: data attribute updated");
        clearTimeout(_guard);
        resolve(src);
        return;
      }
      _poll = setTimeout(check, 250);
    }
    check(); // first check immediately, then every 250 ms
    _guard = setTimeout(() => {
      clearTimeout(_poll);
      reject(new Error("Timeout: LLM result not set after 120 s"));
    }, 120_000);
  });

  // ── 3. Start fetching the static <img> in parallel ───────────────────────
  //    The compositor can't do HTTP fetches, so we resolve the URL to a
  //    data URI before paintDOM. Both LLM calls run concurrently.
  const staticImg = document.querySelector(".static-img");
  const staticLoaded = staticImg ? (async () => {
    // Force PNG — ThorVG has no WebP loader so WebP data URIs are silently skipped.
    const url = (staticImg.getAttribute("src") || "").replace(/format=webp/g, "format=png");
    if (!url.startsWith("http")) return;
    try {
      console.log("[test] fetching static img:", url.slice(0, 80));
      const dataUri = await fetchToDataUri(url);
      staticImg.setAttribute("src", dataUri);
      console.log("[staticLoaded test] static img resolved");
    } catch (err) {
      console.log("[test] static img fetch failed:", err.message);
      staticImg.setAttribute("src", "");   // hide broken-image placeholder
    }
  })() : Promise.resolve();

  // ── 4. Dispatch submit ────────────────────────────────────────────────────
  const form = document.getElementById("gen-form");
  const promptText = form.prompt.value || "";        // capture before DOM is replaced
  console.log("[test] dispatching submit, prompt:", promptText.slice(0, 60));
  form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }));

  // ── 5. Await both: dynamic result + static img ───────────────────────────
  // Both fetches are already in-flight (staticLoaded IIFE + submit handler
  // started above), so awaiting sequentially still gives concurrent execution.
  console.log("[test] waiting for LLM images...");
  await imgLoaded;
  await staticLoaded;
  console.log("[test] all images resolved, painting DOM...");

  // ── 6. Screenshot ──────────────────────────────────────────────────────────
  // Cannot paint the original loaded DOM because:
  //   1. CSS attribute selector ".result-img[src='']" doesn't re-evaluate after JS sets src
  //   2. setAttribute("style", ...) on CSS-processed elements crashes lexbor
  // Fix: capture data URIs, then rebuild as fresh HTML — inline styles set during
  // loadHTML go through loadInlineStyles (not set_attribute) and work correctly.
  const resultSrc = resultEl.getAttribute("src") || "";
  const staticSrc = staticImg ? (staticImg.getAttribute("src") || "") : "";
  const promptLabel = promptText.length > 120 ? promptText.slice(0, 120) + "\u2026" : promptText;

  // Build a compositor-friendly replica of the page layout.
  // Uses only flex+gap for spacing (no margin-bottom/longhand properties).
  __native_loadPage(
    "<div style=\"background:#f5f5f5;padding:32px;display:flex;flex-direction:column;gap:16px\">" +

    // ── Header ──────────────────────────────────────────────────────────────
    "<div style=\"display:flex;flex-direction:column;gap:4px\">" +
      "<div style=\"font-size:22px;font-weight:bold;color:#1a1a1a\">zexplorer \u2014 generative UI</div>" +
      "<div style=\"font-size:13px;color:#666\">LLM-driven headless DOM renderer and screenshot engine.</div>" +
    "</div>" +

    // ── Static embed section ─────────────────────────────────────────────────
    "<div style=\"background:#fff;border-radius:8px;padding:16px;border:1px solid #e0e0e0;display:flex;flex-direction:column;gap:8px\">" +
      "<div style=\"font-size:13px;font-weight:bold;color:#444\">Static embed via GET /render_llm</div>" +
      (staticSrc
        ? "<img src=\"" + staticSrc + "\" style=\"display:block;width:100%;border-radius:4px\">"
        : "<div style=\"font-size:12px;color:#999\">(no static image)</div>") +
    "</div>" +

    // ── Interactive result section ───────────────────────────────────────────
    "<div style=\"background:#fff;border-radius:8px;padding:16px;border:1px solid #e0e0e0;display:flex;flex-direction:column;gap:8px\">" +
      "<div style=\"font-size:13px;font-weight:bold;color:#444\">Interactive prompt (POST /render_llm)</div>" +
      "<div style=\"font-size:11px;color:#888;white-space:pre-wrap\">" + promptLabel + "</div>" +
      (resultSrc
        ? "<img src=\"" + resultSrc + "\" style=\"display:block;width:100%;border-radius:4px\">"
        : "<div style=\"font-size:12px;color:#999\">(no result)</div>") +
    "</div>" +

    "</div>",
    { execute_scripts: false, load_stylesheets: false }
  );
  return zxp.encode(zxp.paintDOM(document.body, 900), "png");
}

run();
