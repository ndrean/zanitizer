const fs = require("fs");
const path = require("path");
const { JSDOM } = require("jsdom");
const createDOMPurify = require("dompurify");

// Read the h5sc test file
const input = fs.readFileSync("src/tests/input/h5sc-test.html", "utf8");

console.log("=== HTML5 Security Cheatsheet Test (DOMPurify) ===");
console.log(`Input size: ${input.length} bytes`);
console.log(`Total vectors: 139\n`);

const dom = new JSDOM("");
const DOMPurify = createDOMPurify(dom.window);

// Sanitize
const start = performance.now();
const output = DOMPurify.sanitize(input);
const end = performance.now();

console.log(`Sanitization time: ${(end - start).toFixed(3)} ms`);
console.log(`Output size: ${output.length} bytes\n`);

// Write output
fs.writeFileSync("src/tests/output/h5sc-dompurify-output.html", output);
console.log("Wrote output to src/tests/output/h5sc-dompurify-output.html");
