console.log("Starting Bun Build REACT for Zexplorer...");

const result = await Bun.build({
  entrypoints: ["BenchReact.jsx"],
  outdir: "../vendor",
  naming: "bench-react.js",
  target: "browser",
  minify: true,
  define: {
    "process.env.NODE_ENV": '"production"',
  },
  jsx: "react",          // classic transform: React.createElement (not jsxDEV)
});

if (!result.success) {
  console.error("❌ Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

console.log("🟢 Build Complete: vendor/app.js");
