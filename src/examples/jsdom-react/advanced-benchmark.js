import { JSDOM } from "jsdom";
import DOMPurify from "dompurify";
import React from "react";
import { renderToString } from "react-dom/server";
import { readFileSync } from "fs";
import { performance } from "perf_hooks";

class BenchmarkRunner {
  constructor(iterations = 100) {
    this.iterations = iterations;
    this.results = {
      jsdom: { times: [], memory: [] },
      react: { times: [], memory: [] },
    };
    this.dirtyHTML = readFileSync("./test.html", "utf8");
    this.cssContent = readFileSync("./styles.css", "utf8");
  }

  measureMemory() {
    if (global.gc) {
      global.gc();
      return process.memoryUsage().heapUsed / 1024 / 1024;
    }
    return 0;
  }

  async runJSDOMTest() {
    console.log("Running JSDOM + DOMPurify test...");

    for (let i = 0; i < this.iterations; i++) {
      const start = performance.now();
      const startMem = this.measureMemory();

      // Sanitize and process
      const window = new JSDOM("").window;
      const purify = DOMPurify(window);
      const cleanHTML = purify.sanitize(this.dirtyHTML);
      const dom = new JSDOM(cleanHTML);
      const document = dom.window.document;

      // DOM operations
      const productCount = document.querySelectorAll(".product").length;
      const hasContainer = !!document.querySelector(".container");
      const trackedCount = document.querySelectorAll(
        '[data-track="true"]',
      ).length;

      dom.window.close();

      const end = performance.now();
      const endMem = this.measureMemory();

      this.results.jsdom.times.push(end - start);
      this.results.jsdom.memory.push(endMem - startMem);
    }
  }

  async runReactTest() {
    console.log("Running React test...");
    const App = () => (
      <html>
        <body>
          <div id="app">
            <div className="container">
              <h1>Test Content</h1>
              <div className="products" data-track="true">
                {[1, 2, 3].map((i) => (
                  <div key={i} className="product">
                    Item {i}
                  </div>
                ))}
              </div>
              <div className="footer">
                <span>Footer content</span>
              </div>
            </div>
          </div>
        </body>
      </html>
    );

    for (let i = 0; i < this.iterations; i++) {
      const start = performance.now();
      const startMem = this.measureMemory();

      const reactHTML = renderToString(<App />);
      const dom = new JSDOM(reactHTML);
      const document = dom.window.document;

      // Add stylesheet
      const style = document.createElement("style");
      style.textContent = this.cssContent;
      document.head.appendChild(style);

      // Same DOM operations
      const productCount = document.querySelectorAll(".product").length;
      const hasContainer = !!document.querySelector(".container");
      const trackedCount = document.querySelectorAll(
        '[data-track="true"]',
      ).length;

      dom.window.close();

      const end = performance.now();
      const endMem = this.measureMemory();

      this.results.react.times.push(end - start);
      this.results.react.memory.push(endMem - startMem);
    }
  }

  printResults() {
    console.log("\n=== FINAL BENCHMARK RESULTS ===\n");

    const calcStats = (arr) => ({
      avg: arr.reduce((a, b) => a + b, 0) / arr.length,
      min: Math.min(...arr),
      max: Math.max(...arr),
      p95: arr.sort((a, b) => a - b)[Math.floor(arr.length * 0.95)],
    });

    console.log("JSDOM + DOMPurify:");
    const jsdomTimeStats = calcStats(this.results.jsdom.times);
    const jsdomMemStats = calcStats(
      this.results.jsdom.memory.filter((m) => m > 0),
    );
    console.log(
      `  Time - Avg: ${jsdomTimeStats.avg.toFixed(2)}ms, Min: ${jsdomTimeStats.min.toFixed(2)}ms, Max: ${jsdomTimeStats.max.toFixed(2)}ms, P95: ${jsdomTimeStats.p95.toFixed(2)}ms`,
    );
    console.log(
      `  Memory - Avg: ${jsdomMemStats.avg.toFixed(2)}MB, Max: ${jsdomMemStats.max.toFixed(2)}MB\n`,
    );

    console.log("React + Stylesheet:");
    const reactTimeStats = calcStats(this.results.react.times);
    const reactMemStats = calcStats(
      this.results.react.memory.filter((m) => m > 0),
    );
    console.log(
      `  Time - Avg: ${reactTimeStats.avg.toFixed(2)}ms, Min: ${reactTimeStats.min.toFixed(2)}ms, Max: ${reactTimeStats.max.toFixed(2)}ms, P95: ${reactTimeStats.p95.toFixed(2)}ms`,
    );
    console.log(
      `  Memory - Avg: ${reactMemStats.avg.toFixed(2)}MB, Max: ${reactMemStats.max.toFixed(2)}MB\n`,
    );

    const speedup = reactTimeStats.avg / jsdomTimeStats.avg;
    console.log(`React is ${speedup.toFixed(2)}x faster on average`);
  }

  async runAll() {
    console.log(`Running benchmark with ${this.iterations} iterations\n`);
    await this.runJSDOMTest();
    await this.runReactTest();
    this.printResults();
  }
}

// Run with garbage collection enabled
const runner = new BenchmarkRunner(100);
runner.runAll().catch(console.error);
