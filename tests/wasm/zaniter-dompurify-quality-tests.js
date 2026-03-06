import { loadZanitize } from '../../../wasm-out/zanitize.js';
import fs from 'fs';
import path from 'path';


const zan = await loadZanitize(new URL('../../wasm-out/zanitize.wasm', import.meta.url));
zan.init();

// Read the same HTML as in sanitizer.zig dom_purify test
const raw_tests = fs.readFileSync(path.join(import.meta.dirname, '../input/dompurify_tests.json'), 'utf8');
const j_tests = JSON.parse(raw_tests);

console.log("=== Zanitizer #tests: ", j_tests.length);

const results = [];
// for (let i = 0; i < j_tests.length; i++) {
    const i = 0
    const result = zan.sanitizeFragment(j_tests[i].payload);
    console.log(result, "\n", j_tests[i].expected);
    results.push({i, test: result == j_tests[i].expected})
// }
const failed = results.filter(r => !r.test);
console.log(failed.length, failed);