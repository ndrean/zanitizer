function click(selector) {
  const el = document.querySelector(selector);
  if (!el) {
    console.log("❌ Not found: " + selector);
    return;
  }
  el.dispatchEvent("click");
}

function measure(name, fn) {
  const start = performance.now();
  fn();
  const end = performance.now();
  console.log(`[${name}] ${(end - start).toFixed(2)} ms`);
}

console.log("\n🚀 Starting VanillaJS-20 Benchmark\n");

measure("Create 1k", () => click("#run"));
measure("Replace 1k", () => click("#run"));

click("#runlots");
measure("Partial Update (10k)", () => click("#update"));

measure("Select Row", () => click("tbody tr:nth-child(2) a.lbl"));

click("#run");
measure("Swap Rows", () => click("#swaprows"));

measure("Remove Row", () => click("tbody tr:nth-child(2) span.remove"));

measure("Create 10k", () => click("#runlots"));
measure("Append 1k", () => click("#add"));
measure("Clear", () => click("#clear"));

const count = document.querySelectorAll("tr").length;
console.log(`✅ Final Row Count: ${count} (Should be 0)`);
