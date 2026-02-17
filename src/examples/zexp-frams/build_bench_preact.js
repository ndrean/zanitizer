console.log("Starting Bun Build PREACT (compat) for Zexplorer...");

const result = await Bun.build({
  entrypoints: ["BenchReact.jsx"],
  outdir: "../vendor",
  naming: "bench-preact.js",
  target: "browser",
  minify: true,
  define: {
    "process.env.NODE_ENV": '"production"',
  },
  plugins: [
    {
      name: "react-to-preact",
      setup(build) {
        build.onResolve({ filter: /^react(-dom)?$/ }, () => {
          return { path: Bun.resolveSync("preact/compat", process.cwd()) };
        });

        build.onResolve({ filter: /^react-dom\/client$/ }, () => {
          return {
            path: Bun.resolveSync("preact/compat/client", process.cwd()),
          };
        });

        build.onResolve({ filter: /^react\/jsx-(dev-)?runtime$/ }, () => {
          return { path: Bun.resolveSync("preact/jsx-runtime", process.cwd()) };
        });
      },
    },
  ],
});

if (!result.success) {
  console.error("❌ Build Failed:");
  for (const msg of result.logs) console.error(msg);
  process.exit(1);
}

console.log("🟢 Build Complete: vendor/bench-preact.js");
