function click(selector) {
  const el = document.querySelector(selector);
  if (!el) {
    console.log("❌ Not found: " + selector);
    return;
  }
  // jsdom needs Event object for dispatchEvent
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

console.log("\n🚀 Starting VanillaJS-2 Benchmark...\n");

// 1. Create 1,000 rows
measure("Create 1k", () => click("#run"));

// 2. Replace all rows (Warmup + Run)
// We click run again, which triggers clear() + add() internally
measure("Replace 1k", () => click("#run"));

// 3. Partial Update (Warmup: Create 10k first)
click("#runlots"); // Setup 10k
measure("Partial Update (10k)", () => click("#update"));

// 4. Select Row
// We select the second row's label
measure("Select Row", () => click("tbody tr:nth-child(2) a.lbl"));

// 5. Swap Rows (Reset to 1k first)
click("#run"); // Reset to 1k
measure("Swap Rows", () => click("#swaprows"));

// 6. Remove Row
// Remove the 2nd row
measure("Remove Row", () => click("tbody tr:nth-child(2) span.remove"));

// 7. Create 10,000 Rows
measure("Create 10k", () => click("#runlots"));

// 8. Append 1,000 Rows (to the existing 10k)
measure("Append 1k", () => click("#add"));

// 9. Clear Rows
measure("Clear", () => click("#clear"));

const count = document.querySelectorAll("tr").length;
console.log(`✅ Final Row Count: ${count} (Should be 0)`);
