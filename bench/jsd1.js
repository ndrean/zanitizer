const { JSDOM } = require("jsdom");

console.log("=== JSDOM Detailed Benchmark ===\n");

// Test 1: Pure DOM creation (no text/attributes)
function testPureCreation(iterations) {
  const dom = new JSDOM(`<!DOCTYPE html><html><body></body></html>`);
  const { document } = dom.window;

  const start = process.hrtime.bigint();

  for (let i = 0; i < iterations; i++) {
    document.createElement("div");
  }

  const end = process.hrtime.bigint();
  return Number(end - start) / 1000000; // ms
}

// Test 2: Creation + textContent
function testWithText(iterations) {
  const dom = new JSDOM(`<!DOCTYPE html><html><body></body></html>`);
  const { document } = dom.window;

  const start = process.hrtime.bigint();

  for (let i = 0; i < iterations; i++) {
    const el = document.createElement("div");
    el.textContent = `Item ${i}`;
  }

  const end = process.hrtime.bigint();
  return Number(end - start) / 1000000;
}

// Test 3: Full test (creation + text + attribute + append)
function testFull(iterations) {
  const dom = new JSDOM(`<!DOCTYPE html><html><body></body></html>`);
  const { document } = dom.window;
  const container = document.createElement("div");

  const start = process.hrtime.bigint();

  for (let i = 0; i < iterations; i++) {
    const el = document.createElement("div");
    el.textContent = `Item ${i}`;
    el.setAttribute("data-id", i.toString());
    container.appendChild(el);
  }

  const end = process.hrtime.bigint();
  return Number(end - start) / 1000000;
}

const iterations = 30000;

console.log(`Running ${iterations.toLocaleString()} iterations each:\n`);

const time1 = testPureCreation(iterations);
console.log(
  `1. Pure createElement: ${time1.toFixed(2)}ms (${(
    (time1 * 1000) /
    iterations
  ).toFixed(2)}µs/op)`
);

const time2 = testWithText(iterations);
console.log(
  `2. + textContent: ${time2.toFixed(2)}ms (${(
    (time2 * 1000) /
    iterations
  ).toFixed(2)}µs/op)`
);

const time3 = testFull(iterations);
console.log(
  `3. Full (create+text+attr+append): ${time3.toFixed(2)}ms (${(
    (time3 * 1000) /
    iterations
  ).toFixed(2)}µs/op)`
);

console.log(`\nRatio - Full / Basic: ${(time3 / time1).toFixed(2)}x`);
