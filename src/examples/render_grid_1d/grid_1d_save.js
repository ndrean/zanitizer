const file = "file://src/examples/render_grid_1d/grid_1d.html";

async function render() {
  const file_data = await fetch(file);
  const html = await file_data.text();
  zxp.loadHTML(html);
  const img = zxp.paintDOM(document.body);
  zxp.save(img, "src/examples/render_grid_1d/grid_1d.pdf");
}

render();
