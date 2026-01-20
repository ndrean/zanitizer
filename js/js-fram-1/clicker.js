// driver.js - The "Click Generator"

function click(id) {
  const el = document.getElementById(id);
  console.log("Cicked :", el.id);
  if (!el) {
    console.error("❌ Element not found: #" + id);
    return;
  }
  /// jsdom needs Event object for dispatchEvent
  el.dispatchEvent(new Event("click", { bubbles: true }));

  // Dispatch the click. Bubbling is handled by engine
  // el.dispatchEvent("click");
}

function measure(name, actionId) {
  const start = Date.now();
  click(actionId);
  // In a real browser, we'd wait for layout repaint here.
  // In Zexplorer, execution is synchronous, so we are done immediately!
  const end = Date.now();
  console.log(`[${name}] took ${end - start} ms`);
}

console.log("🚀 Starting Benchmark...");

// 1. Create 1,000 Rows
measure("Create 1k", "run");

// 2. Clear
measure("Clear", "clear");

// 3. Create 10,000 Rows (The stress test)
measure("Create 10k", "runlots");

// 4. Append 1,000 Rows
measure("Append 1k", "add");

// 5. Update every 10th row
measure("Update", "update");

// 6. Swap Rows
measure("Swap", "swaprows");

// 7. Verify Data (Sanity Check)
const rows = document.querySelectorAll("tr");
console.log(`✅ Final Row Count: ${rows.length}`);
