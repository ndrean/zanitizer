import { compile } from "svelte/compiler";
import { writeFileSync, unlinkSync } from "fs";

console.log("Starting Bun Build SVELTE for Zexplorer...");

// Compile .svelte -> JS
const source = await Bun.file("BenchSvelte.svelte").text();
const { js } = compile(source, {
  generate: "client",
  css: "injected",
  dev: false,
});

// Write compiled component to a temp file, then create entry that imports it
writeFileSync("_svelte_component.js", js.code);

const entryCode = `
import { mount } from "svelte";
import Component from "./_svelte_component.js";
mount(Component, { target: document.getElementById("main") });
`;
writeFileSync("_svelte_entry.js", entryCode);

// Step 3: Bundle compiled output + svelte runtime
const result = await Bun.build({
  entrypoints: ["_svelte_entry.js"],
  outdir: "../vendor",
  naming: "bench-svelte.js",
  target: "browser",
  minify: true,
});

unlinkSync("_svelte_entry.js");
try {
  unlinkSync("_svelte_component.js");
} catch (e) {}

if (!result.success) {
  console.error("Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

console.log("Build Complete: vendor/bench-svelte.js");
