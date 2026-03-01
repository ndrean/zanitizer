console.log("Starting Bun Build REACT for Zexplorer...");

const result = await Bun.build({
  entrypoints: ["App.jsx"],
  outdir: "../vendor",
  naming: "app.js",
  target: "browser",
  minify: true,
});

if (!result.success) {
  console.error("❌ Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

console.log("🟢 Build Complete: vendor/app.js");
