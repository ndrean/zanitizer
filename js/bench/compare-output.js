const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');
const createDOMPurify = require('dompurify');

const dom = new JSDOM('');
const DOMPurify = createDOMPurify(dom.window);
const dirty = fs.readFileSync(path.join(__dirname, 'dirty.html'), 'utf8');
const result = DOMPurify.sanitize(dirty);

// Write DOMPurify output
fs.writeFileSync('dompurify-output.html', result);
console.log('DOMPurify output saved to dompurify-output.html');
console.log(`Output size: ${result.length} bytes`);
