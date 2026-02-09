console.log("Starting Bun Build Chart.js for Zexplorer...");

const result = await Bun.build({
  entrypoints: ["chartjs_entry.js"],
  outdir: "../vendor",
  naming: "chart.js",
  target: "browser",
  format: "iife",
  minify: false,
});

if (!result.success) {
  console.error("❌ Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

console.log("🟢 Build Complete: dist/chart.js");
