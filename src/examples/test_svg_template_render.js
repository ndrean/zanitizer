// SVG template renderer: takes an SVG background + data object,
// renders the SVG, then overlays dynamic text fields on the canvas.
//
// Called from Zig with globals: TEMPLATE_SVG (string), TEMPLATE_DATA (object)
// TEMPLATE_DATA fields: { title, subtitle, author, footer, width, height }

async function renderTemplate(svgText, data) {
  const blob = new Blob([svgText], { type: "image/svg+xml" });
  const img = await createImageBitmap(blob);

  const w = data.width || 1200;
  const h = data.height || 630;

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");

  // White background fallback
  ctx.fillStyle = "white";
  ctx.fillRect(0, 0, w, h);

  // Draw the SVG template as background (scaled to fill)
  ctx.drawImage(img, 0, 0, img.width, img.height, 0, 0, w, h);

  // --- Overlay dynamic text ---

  // Title (large, prominent)
  if (data.title) {
    ctx.fillStyle = data.titleColor || "white";
    ctx.font = data.titleFont || "bold 48px";
    ctx.fillText(data.title, 60, 260);
  }

  // Subtitle
  if (data.subtitle) {
    ctx.fillStyle = data.subtitleColor || "#cccccc";
    ctx.font = data.subtitleFont || "28px";
    ctx.fillText(data.subtitle, 60, 320);
  }

  // Author
  if (data.author) {
    ctx.fillStyle = data.authorColor || "#aaaaaa";
    ctx.font = data.authorFont || "22px";
    ctx.fillText(data.author, 60, 380);
  }

  // Footer (bottom-left)
  if (data.footer) {
    ctx.fillStyle = data.footerColor || "#666666";
    ctx.font = data.footerFont || "18px";
    ctx.fillText(data.footer, 60, h - 40);
  }

  const result = await canvas.toBlob();
  return await result.arrayBuffer();
}
