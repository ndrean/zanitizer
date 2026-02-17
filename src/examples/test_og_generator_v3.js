// OG Image Generator v3 — uses native arrayBufferToBase64DataUri
// Avatar is embedded as a base64 data URI directly in the SVG template,
// then the entire SVG is rasterized in one pass (no layered canvas composition).

async function generateOGImage({ title, author, avatarUrl }) {
  console.log(`Generating OG Image (v3) for: ${title}`);

  // 1. Fetch avatar as raw bytes
  const avatarRes = await fetch(avatarUrl);
  const avatarBuffer = await avatarRes.arrayBuffer();
  const contentType = avatarRes.headers.get("content-type") || "image/jpeg";
  console.log(`Avatar: ${avatarBuffer.byteLength} bytes, ${contentType}`);

  // 2. Convert to base64 data URI using native Zig function
  const avatarDataUri = arrayBufferToBase64DataUri(avatarBuffer, contentType);
  console.log(`Data URI length: ${avatarDataUri.length}`);

  // 3. Load SVG template and substitute placeholders
  const templRes = await fetch("file://src/examples/test_og_generator_template_v3.svg");
  const rawSvgTemplate = await templRes.text();
  const finalSvg = rawSvgTemplate
    .replace("{{AVATAR_B64}}", avatarDataUri)
    .replace("{{TITLE}}", title)
    .replace("{{AUTHOR}}", author);

  // 4. Rasterize the complete SVG in one pass
  const svgBlob = new Blob([finalSvg], { type: "image/svg+xml" });
  const bitmap = await createImageBitmap(svgBlob);

  // 5. Draw to canvas and export as PNG
  const canvas = document.createElement("canvas");
  canvas.width = 1200;
  canvas.height = 630;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0);

  const pngBlob = await canvas.toBlob();
  return await pngBlob.arrayBuffer();
}

async function renderTemplate() {
  try {
    const pngBytes = await generateOGImage({
      title: "Headless Browser in Zig",
      author: "N. Drean",
      avatarUrl: "https://github.com/torvalds.png",
    });
    console.log(`PNG output: ${pngBytes.byteLength} bytes`);
    return pngBytes;
  } catch (e) {
    console.error("Failed to generate OG image:", e);
  }
}
