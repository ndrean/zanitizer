import { transformSync } from "@babel/core";
import solidPreset from "babel-preset-solid";
import { readFileSync, writeFileSync } from "fs";

console.log("Starting Bun Build Solid for Zexplorer...");

// Step 1: Transform JSX with babel-preset-solid
// (Bun's built-in JSX transform would use React, not Solid,
//  so we run babel separately first)
const source = readFileSync("BenchSolid.js", "utf8");
const babelResult = transformSync(source, {
  presets: [[solidPreset, { generate: "dom" }]],
  filename: "BenchSolid.js",
});

const compiledPath = "BenchSolid.compiled.js";
writeFileSync(compiledPath, babelResult.code);
console.log("  Babel transform done -> " + compiledPath);

// Step 2: Bundle the compiled (plain JS) output with Bun
const result = await Bun.build({
  entrypoints: [compiledPath],
  outdir: "../vendor",
  naming: "bench-solid.js",
  target: "browser",
  minify: false,
});

if (!result.success) {
  console.error("Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

console.log("Build Complete: vendor/bench-solid.js");
