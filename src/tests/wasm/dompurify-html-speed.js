import { loadZanitize } from '../../../wasm-out/zanitize.js';
import fs from 'fs';
import path from 'path';


const zan = await loadZanitize(new URL('../../../wasm-out/zanitize.wasm', import.meta.url));
zan.init();

const dirty = fs.readFileSync(path.join(import.meta.dirname, '../input/dirty.html'), 'utf8');

console.log('=== Zanitizer Benchmark ===');
console.log(`Input size: ${dirty.length} bytes`);

// Warmup
for (let i = 0; i < 10; i++) {
  zan.sanitize(dirty);
}

const iterations = 100;
const start = performance.now();
let result;
for (let i = 0; i < iterations; i++) {
  result = zan.sanitize(dirty);
}
const end = performance.now();

const avgTime = (end - start) / iterations;
console.log(`Average time (${iterations} iterations): ${avgTime.toFixed(2)} ms`);
console.log(`Output size: ${result.length} bytes`);

// Single run for comparison
const singleStart = performance.now();
const singleResult = zan.sanitize(dirty);
const singleEnd = performance.now();
console.log(`Single run: ${(singleEnd - singleStart).toFixed(2)} ms`);

console.log(`Zaniter (this machine): ${avgTime.toFixed(2)} ms`);
