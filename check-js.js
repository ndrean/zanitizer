const fs = require('fs');
const zig = fs.readFileSync('zig-output.html', 'utf8');
const dp = fs.readFileSync('js/bench/dompurify-output.html', 'utf8');

const zigJS = (zig.match(/javascript:/g) || []).length;
const dpJS = (dp.match(/javascript:/g) || []).length;

console.log('\n=== Security Fix Verification ===\n');
console.log('javascript: URIs:');
console.log(`  Zig (FIXED): ${zigJS}`);
console.log(`  DOMPurify:   ${dpJS}`);
console.log(`  Status: ${zigJS <= dpJS ? '✓ SECURE (equal or better)' : '✗ VULNERABLE (more than DOMPurify)'}`);

console.log('\n=== Sample javascript: URIs in Zig output ===');
const matches = Array.from(zig.matchAll(/[^>]{0,50}javascript:[^<]{0,50}/g));
for (let i = 0; i < Math.min(5, matches.length); i++) {
  console.log(`  ${matches[i][0]}`);
}

console.log('\n=== Output sizes ===');
console.log(`  Zig:       ${zig.length} bytes`);
console.log(`  DOMPurify: ${dp.length} bytes`);
console.log(`  Difference: ${dp.length - zig.length} bytes (Zig removes ${((1 - zig.length/dp.length)*100).toFixed(1)}% more)`);
