async function renderSVG(svg_text_buffer) {
  const blob = new Blob([svg_text_buffer], { type: "image/svg+xml" });
  const img = await createImageBitmap(blob);

  console.log("[JS] SVG from Blob:", img.width, "x", img.height);

  const canvas = document.createElement("canvas");
  const w = 800;
  const h = (w * img.height) / img.width;
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");

  ctx.fillStyle = "white";
  ctx.fillRect(0, 0, w, h);
  ctx.drawImage(img, 0, 0, img.width, img.height, 0, 0, w, h);

  ctx.fillStyle = "blue";
  ctx.font = "20px";
  ctx.fillText("Read and render SVG via Blob", 10, 390);

  // return value to Zig
  const result = await canvas.toBlob();
  return await result.arrayBuffer();
}
