import React from "react";
import { renderToString } from "react-dom/server";
import { JSDOM } from "jsdom";
import { performance } from "perf_hooks";
import { readFileSync } from "fs";

// React component with stylesheet
const App = () => {
  return (
    <html>
      <head>
        <title>React Test Page</title>
        <link rel="stylesheet" href="/styles.css" />
      </head>
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
};

// Load CSS for simulation
const cssContent = readFileSync("./styles.css", "utf8");

async function runReactBenchmark(iterations = 1000) {
  console.log("\n=== React + Stylesheet Benchmark ===");
  console.log(`Running ${iterations} iterations...\n`);

  // Warm-up
  for (let i = 0; i < 10; i++) {
    renderToString(<App />);
  }

  // Test 1: React renderToString only
  performance.mark("react-render-start");

  for (let i = 0; i < iterations; i++) {
    renderToString(<App />);
  }

  performance.mark("react-render-end");
  performance.measure(
    "React renderToString",
    "react-render-start",
    "react-render-end",
  );

  // Test 2: React render + JSDOM + CSS injection + selections
  performance.mark("react-full-start");

  for (let i = 0; i < iterations; i++) {
    // Render React to HTML
    const reactHTML = renderToString(<App />);

    // Create DOM
    const dom = new JSDOM(reactHTML);
    const document = dom.window.document;

    // Inject stylesheet (simulating loading)
    const style = document.createElement("style");
    style.textContent = cssContent;
    document.head.appendChild(style);

    // DOM selections (same as JSDOM benchmark)
    const products = document.querySelectorAll(".product");
    const container = document.querySelector(".container");
    const trackedElements = document.querySelectorAll('[data-track="true"]');

    // Count products
    const productCount = products.length;

    dom.window.close();
  }

  performance.mark("react-full-end");
  performance.measure(
    "React + DOM + CSS",
    "react-full-start",
    "react-full-end",
  );
}

runReactBenchmark(1000);
