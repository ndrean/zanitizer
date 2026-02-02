function click(fn) {
  fn();
}

function measure(name, fn) {
  const start = Date.now();
  fn();
  const end = Date.now();
  console.log(`[${name}] ${end - start} ms`);
}

console.log("\n🚀 Starting Bau Benchmark...\n");

measure("Create 1k", () => click(run));
// We click run again, which triggers clear() + add() internally
measure("Replace 1k", () => click("#run"));

// Partial Update (Warmup: Create 10k first)
click("#runlots"); // Setup 10k
measure("Partial Update (10k)", () => click("#update"));

// Select Row: the second row's label
measure("Select Row", () => click("tbody tr:nth-child(2) a.lbl"));
// Swap Rows (Reset to 1k first)
click("#run"); // Reset to 1k
measure("Swap Rows", () => click("#swaprows"));
// Remove the 2nd row
measure("Remove Row", () => click("tbody tr:nth-child(2) span.remove"));
measure("Create 10k", () => click("#runlots"));
// Append 1,000 Rows (to the existing 10k)
measure("Append 1k", () => click("#add"));
measure("Clear", () => click("#clear"));
// sanity check
const count = document.querySelectorAll("tr").length;
console.log(`✅ Final Row Count: ${count} (Should be 0)`);
