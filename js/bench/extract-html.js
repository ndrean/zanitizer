const fs = require('fs');
const path = require('path');

// Read the sanitizer.zig file
const zigFile = fs.readFileSync(
  path.join(__dirname, '../../src/modules/sanitizer.zig'),
  'utf8'
);

// Find the dom_purify test
const testStart = zigFile.indexOf('test "dom_purify"');
const dirtyStart = zigFile.indexOf('const dirty =', testStart);
const contentStart = zigFile.indexOf('\\\\', dirtyStart);
const contentEnd = zigFile.indexOf('\n    ;', contentStart);

// Extract lines between dirty = and ;
const lines = zigFile.substring(contentStart, contentEnd).split('\n');
const htmlLines = lines
  .filter(line => line.trim().startsWith('\\\\'))
  .map(line => line.replace(/^\s*\\\\/, ''));

const dirty = htmlLines.join('\n');

// Write to file
fs.writeFileSync(path.join(__dirname, 'dirty.html'), dirty);
console.log(`Extracted ${dirty.length} bytes to dirty.html`);
