// --- Helper Functions ---

function click(selector) {
  const el = document.querySelector(selector);
  if (!el) {
    console.log("❌ Not found: " + selector);
    return;
  }

  // Custom Engine: We pass the event name as a string.
  // The engine MUST handle bubbling from 'el' up to the listener parents.
  el.dispatchEvent("click");
}

function measure(name, fn) {
  const start = Date.now();
  fn();
  const end = Date.now();
  console.log(`[${name}] ${end - start} ms`);
}

// --- Benchmark Suite ---

console.log("\n🚀 Starting VanillaJS-3 Benchmark (EventListener Version)...\n");

// 1. Create 1,000 rows
// We click the button #run.
// The event must bubble to #app-actions div where the listener is attached.
measure("Create 1k", () => click("#run"));

// 2. Replace all rows
measure("Replace 1k", () => click("#run"));

// 3. Partial Update
// Setup 10k first
click("#runlots");
measure("Partial Update (10k)", () => click("#update"));

// 4. Select Row
// We click the <a> tag.
// The event must bubble to 'tbody' where the listener checks e.target.tagName === 'A'
measure("Select Row", () => click("tbody tr:nth-child(2) a.lbl"));

// 5. Swap Rows
click("#run"); // Reset to 1k
measure("Swap Rows", () => click("#swaprows"));

// 6. Remove Row
// We click the <span> tag.
// The event must bubble to 'tbody' where the listener checks e.target.tagName === 'SPAN'
measure("Remove Row", () => click("tbody tr:nth-child(2) span.remove"));

// 7. Create 10,000 Rows
measure("Create 10k", () => click("#runlots"));

// 8. Append 1,000 Rows
measure("Append 1k", () => click("#add"));

// 9. Clear Rows
measure("Clear", () => click("#clear"));

// --- Verification ---
const count = document.querySelectorAll("tr").length;
if (count !== 0) console.log(`❌ Leaked Rows: ${count}`);
else console.log(`✅ Clean Run`);
