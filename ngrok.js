async function run() {
  await zxp.goto("http://localhost:4173");

  // Force light mode: `:root` dark-theme color cascades as invisible white text
  // and @media prefers-color-scheme is not evaluated by the compositor.
  const fix = document.createElement("style");
  fix.textContent = "body { background-color: #fff; color: #213547; }";
  document.head.appendChild(fix);

  const img = zxp.paintDOM(document.body, 1200);
  return zxp.encode(img, "png");
}
run();
