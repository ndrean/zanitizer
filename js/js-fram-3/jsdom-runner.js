const fs = require("fs");
const { JSDOM, VirtualConsole } = require("jsdom");
const { performance } = require("perf_hooks");

const html = fs.readFileSync("index.html", "utf8");
const appCode = fs.readFileSync("js-vanilla-bench3.js", "utf8");

const virtualConsole = new VirtualConsole();
virtualConsole.forwardTo(console);

const dom = new JSDOM(html, {
  runScripts: "dangerously",
  resources: "usable",
  virtualConsole,
});

const { window } = dom;
const { document } = window;

// Global Polyfills (Crucial for some frameworks/benchmarks)
global.window = window;
global.document = document;
global.Node = window.Node;
global.HTMLElement = window.HTMLElement;
global.Event = window.Event;
global.MouseEvent = window.MouseEvent;

console.log("\n--- 🐢 Starting JSDOM Benchmark (Standard API) ---\n");

try {
  // Load the Application Code
  // This registers the addEventListener('click') on body/app-actions
  window.eval(appCode);

  // Define the Driver Helper (JSDOM Version)
  // We can't use your 'driver.js' directly because JSDOM needs 'new MouseEvent'
  const click = (selector) => {
    const el = document.querySelector(selector);
    if (!el) {
      console.log(`❌ Not found: ${selector}`);
      return;
    }

    // JSDOM requires the formal event construction
    const event = new window.MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      view: window,
    });
    el.dispatchEvent(event);
  };

  const measure = (name, fn) => {
    const start = performance.now();
    fn();
    const end = performance.now();
    console.log(`[${name}] ${(end - start).toFixed(2)} ms`);
  };

  // Run the Benchmark
  measure("Create 1k", () => click("#run"));
  measure("Replace 1k", () => click("#run")); // clear + add

  click("#runlots"); // Setup 10k
  measure("Partial Update (10k)", () => click("#update"));

  measure("Select Row", () => click("tbody tr:nth-child(2) a.lbl"));

  click("#run"); // Reset to 1k
  measure("Swap Rows", () => click("#swaprows"));

  measure("Remove Row", () => click("tbody tr:nth-child(2) span.remove"));

  measure("Create 10k", () => click("#runlots"));

  measure("Append 1k", () => click("#add"));

  measure("Clear", () => click("#clear"));

  const count = document.querySelectorAll("tr").length;
  console.log(`\n✅ Final Row Count: ${count}`);
} catch (e) {
  console.error("Benchmark Crashed:", e);
}
