const fs = require('fs');

const zigOutput = fs.readFileSync('zig-output.html', 'utf8');
const dompurifyOutput = fs.readFileSync('dompurify-output.html', 'utf8');

console.log('=== Key Differences ===\n');

// Check for specific elements/patterns
const patterns = [
  ['<image', 'SVG image elements'],
  ['<use', 'SVG use elements'],
  ['<a', 'Anchor elements'],
  ['<math', 'MathML elements'],
  ['<svg', 'SVG elements'],
  ['<script', 'Script tags'],
  ['<style', 'Style tags'],
  ['onclick', 'onclick attributes'],
  ['onerror', 'onerror attributes'],
  ['javascript:', 'javascript: URIs'],
  ['<template', 'Template elements'],
];

patterns.forEach(([pattern, desc]) => {
  const zigCount = (zigOutput.match(new RegExp(pattern, 'gi')) || []).length;
  const dpCount = (dompurifyOutput.match(new RegExp(pattern, 'gi')) || []).length;
  if (zigCount !== dpCount) {
    console.log(`${desc}:`);
    console.log(`  Zig: ${zigCount}, DOMPurify: ${dpCount}, Diff: ${dpCount - zigCount}`);
  }
});

console.log('\n=== Size Breakdown ===');
console.log(`Zig output: ${zigOutput.length} bytes`);
console.log(`DOMPurify output: ${dompurifyOutput.length} bytes`);
const diff = dompurifyOutput.length - zigOutput.length;
const pct = (diff / dompurifyOutput.length * 100).toFixed(1);
console.log(`Difference: ${diff} bytes (${pct}% more content in DOMPurify)`);

// Sample what DOMPurify keeps that Zig removes
console.log('\n=== Sample: First SVG image in DOMPurify output ===');
const imageMatch = dompurifyOutput.match(/<image[^>]*>/);
if (imageMatch) {
  console.log(imageMatch[0].substring(0, 200) + '...');
}

// Check for MathML
console.log('\n=== MathML Handling ===');
const zigMath = zigOutput.match(/<math[\s\S]*?<\/math>/gi) || [];
const dpMath = dompurifyOutput.match(/<math[\s\S]*?<\/math>/gi) || [];
console.log(`Zig keeps ${zigMath.length} <math> blocks`);
console.log(`DOMPurify keeps ${dpMath.length} <math> blocks`);

if (zigMath.length > 0) {
  console.log('\nFirst MathML in Zig output (truncated):');
  console.log(zigMath[0].substring(0, 150) + '...');
}
