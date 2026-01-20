const fs = require("fs");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;

const html = fs.readFileSync("index.html", "utf8");
const appCode = fs.readFileSync("js-vanilla-bench1.js", "utf8");
const driverCode = fs.readFileSync("clicker.js", "utf8");

const virtualConsole = new jsdom.VirtualConsole();
virtualConsole.forwardTo(console);

// Initialize JSDOM
// We use 'runScripts: "dangerously"' to allow executing JS.
const dom = new JSDOM(html, {
  runScripts: "dangerously",
  resources: "usable",
  virtualConsole,
});

const { window } = dom;

// Polyfill global environment (optional but good for some libs)
// JSDOM isolates variables, but the benchmark might rely on global behavior
global.window = window;
global.document = window.document;

console.log("--- Starting JSDOM Benchmark ---");

try {
  // Run the Application Code (Setup event listeners)
  window.eval(appCode);

  // Run the Driver (Perform clicks and measurements)
  window.eval(driverCode);
} catch (e) {
  console.error("Benchmark failed:", e);
}
