const fs = require("fs");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;

// 1. Load the files
const html = fs.readFileSync("index.html", "utf8");
const appCode = fs.readFileSync("js-benchmark.js", "utf8");
const driverCode = fs.readFileSync("driver.js", "utf8");

// 2. Configure Virtual Console (to see console.log output)
const virtualConsole = new jsdom.VirtualConsole();
virtualConsole.forwardTo(console);

// 3. Initialize JSDOM
// We use 'runScripts: "dangerously"' to allow executing JS.
const dom = new JSDOM(html, {
  runScripts: "dangerously",
  resources: "usable",
  virtualConsole,
});

const { window } = dom;

// 4. Polyfill global environment (optional but good for some libs)
// JSDOM isolates variables, but the benchmark might rely on global behavior
global.window = window;
global.document = window.document;

console.log("--- Starting JSDOM Benchmark ---");

try {
  // 5. Run the Application Code (Setup event listeners)
  window.eval(appCode);

  // 6. Run the Driver (Perform clicks and measurements)
  window.eval(driverCode);
} catch (e) {
  console.error("Benchmark failed:", e);
}
