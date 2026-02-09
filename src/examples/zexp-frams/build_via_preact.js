// scripts/build_react.js
console.log("🚀 Starting Bun Build for Zexplorer...");

const result = await Bun.build({
  entrypoints: ["App.jsx"],
  outdir: "../vendor",
  naming: "app.js", // Force output filename
  target: "browser",
  minify: true, // Optional: keep it small for your 1ms boot
  plugins: [
    {
      name: "react-to-preact",
      setup(build) {
        // Intercept "react" and "react-dom" imports
        build.onResolve({ filter: /^react(-dom)?$/ }, () => {
          return { path: Bun.resolveSync("preact/compat", process.cwd()) };
        });

        build.onResolve({ filter: /^react-dom\/client$/ }, () => {
          // preact/compat/client is the file that exports createRoot
          return {
            path: Bun.resolveSync("preact/compat/client", process.cwd()),
          };
        });

        // 2. Intercept JSX Runtime
        // Bun/React injects "react/jsx-runtime" or "react/jsx-dev-runtime"
        build.onResolve({ filter: /^react\/jsx-(dev-)?runtime$/ }, () => {
          return { path: Bun.resolveSync("preact/jsx-runtime", process.cwd()) };
        });
      },
    },
  ],
});

if (!result.success) {
  console.error("❌ Build Failed:");
  for (const msg of result.logs) {
    console.error(msg);
  }
  process.exit(1);
}

console.log("🟢 Build Complete: dist/app.js");
