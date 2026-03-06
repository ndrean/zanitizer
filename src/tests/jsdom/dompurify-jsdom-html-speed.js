const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const createDOMPurify = require('dompurify');

const dom = new JSDOM('');
const DOMPurify = createDOMPurify(dom.window);

// Read the same HTML as in sanitizer.zig dom_purify test
const dirty = fs.readFileSync(path.join(__dirname, '../input/dirty.html'), 'utf8');

console.log('=== DOMPurify Benchmark ===');
console.log(`Input size: ${dirty.length} bytes`);

// Warmup
for (let i = 0; i < 10; i++) {
  DOMPurify.sanitize(dirty);
}

// Benchmark
const iterations = 100;
const start = performance.now();
let result;
for (let i = 0; i < iterations; i++) {
  result = DOMPurify.sanitize(dirty);
}
const end = performance.now();

const avgTime = (end - start) / iterations;
console.log(`Average time (${iterations} iterations): ${avgTime.toFixed(2)} ms`);
console.log(`Output size: ${result.length} bytes`);

// Single run for comparison
const singleStart = performance.now();
const singleResult = DOMPurify.sanitize(dirty);
const singleEnd = performance.now();
console.log(`Single run: ${(singleEnd - singleStart).toFixed(2)} ms`);

console.log(`DOMPurify (this machine): ${avgTime.toFixed(2)} ms`);
