import { loadZanitize } from '../../../wasm-out/zanitize.js';
import fs from 'fs';
import path from 'path';


const zan = await loadZanitize(new URL('../../../wasm-out/zanitize.wasm', import.meta.url));
zan.init();

const input = fs.readFileSync(path.join(import.meta.dirname, '../input/h5sc-test.html'), 'utf8');

console.log("=== HTML5 Security Cheatsheet Test (Zaniter) ===");
console.log(`Input size: ${input.length} bytes`);


const start = performance.now();
const output = zan.sanitize(input);
const end = performance.now();

console.log(`Sanitization time: ${(end - start).toFixed(3)} ms`);
console.log(`Output size: ${output.length} bytes\n`);

// Write output
fs.writeFileSync("src/tests/output/h5sc-zanitizer-output.html", output);
console.log("Wrote output to tests/output/h5sc-zanitizer-output.html");