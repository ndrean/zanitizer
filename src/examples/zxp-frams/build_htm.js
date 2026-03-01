console.log("Starting Bun Build htm for Zexplorer...");

const result = await Bun.build({
  entrypoints: ["htm_entry.js"],
  outdir: "../vendor",
  naming: "htm.js",
  target: "browser",
  format: "iife",
  minify: true,
});

if (!result.success) {
  console.error("Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

// Show the size
const file = Bun.file("../vendor/htm.js");
const size = file.size;
console.log(`Build Complete: vendor/htm.js (${size} bytes)`);
