const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const createDOMPurify = require('dompurify');

const dom = new JSDOM('');
const DOMPurify = createDOMPurify(dom.window);

// Read the same HTML as in sanitizer.zig dom_purify test
const raw_tests = fs.readFileSync(path.join(__dirname, '../input/dompurify_tests.json'), 'utf8');
const j_tests = JSON.parse(raw_tests);

console.log("=== D0MPURIFY #tests: ", j_tests.length);

const results = [];
for (let i = 0; i < j_tests.length; i++) {
    const result = DOMPurify.sanitize(j_tests[i].payload);
    results.push({i, test: result == j_tests[i].expected})
}
const failed = results.filter(r => !r.test);
console.log(failed.length, failed);


