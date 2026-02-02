function click(selector) {
  const el = document.querySelector(selector);
  if (!el) {
    console.log("❌ Not found: " + selector);
    return;
  }

  /// jsdom needs Event object for dispatchEvent
  // el.dispatchEvent(new Event("click", { bubbles: true }));

  // Dispatch the click. Bubbling is handled by engine
  el.dispatchEvent("click");
}

function measure(name, fn) {
  const start = Date.now();
  fn();
  const end = Date.now();
  console.log(`[${name}] ${end - start} ms`);
}

// --- Benchmark Suite ---

console.log("\n🚀 Starting VanillaJS-1 Benchmark (EventListener Version)...\n");

// 1. Create 1,000 rows
// We click the button #run.
// The event must bubble to #app-actions div where the listener is attached.
measure("Create 1k", () => click("#run"));

// Replace all rows
measure("Replace 1k", () => click("#run"));

// Partial Update
// Setup 10k first
click("#runlots");
measure("Partial Update (10k)", () => click("#update"));

// Select Row
// We click the <a> tag.
// The event must bubble to 'tbody' where the listener checks e.target.tagName === 'A'
measure("Select Row", () => click("tbody tr:nth-child(2) a.lbl"));

// Swap Rows
click("#run"); // Reset to 1k
measure("Swap Rows", () => click("#swaprows"));

// Remove Row
// We click the <span> tag.
// The event must bubble to 'tbody' where the listener checks e.target.tagName === 'SPAN'
measure("Remove Row", () => click("tbody tr:nth-child(2) span.remove"));

// Create 10,000 Rows
measure("Create 10k", () => click("#runlots"));

// Append 1,000 Rows
measure("Append 1k", () => click("#add"));

// Clear Rows
measure("Clear", () => click("#clear"));

// sanity check
const count = document.querySelectorAll("tr").length;
if (count !== 0) console.log(`❌ Leaked Rows: ${count}`);
else console.log(`✅ Clean Run`);
