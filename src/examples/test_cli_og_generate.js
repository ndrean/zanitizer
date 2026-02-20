// src/examples/generate_og.js

// 1. Read ammunition from the CLI, falling back to defaults
const title = zxp.args[0] || "Headless Browser in Zig";
const author = zxp.args[1] || "Default Author";
const avatarUrl = zxp.args[2] || "https://github.com/torvalds.png";

console.log(`[JS] Generating OG Image for: "${title}" by ${author}`);

async function generateOGImage() {
  const avatarRes = await fetch(avatarUrl);
  const avatarBuffer = await avatarRes.arrayBuffer();
  const contentType = avatarRes.headers.get("content-type") || "image/jpeg";

  const avatarDataUri = arrayBufferToBase64DataUri(avatarBuffer, contentType);

  const templRes = await fetch(
    "file://src/examples/test_og_generator_template_v3.svg",
  );
  const rawSvgTemplate = await templRes.text();
  const finalSvg = rawSvgTemplate
    .replace("{{AVATAR_B64}}", avatarDataUri)
    .replace("{{TITLE}}", title)
    .replace("{{AUTHOR}}", author);

  const svgBlob = new Blob([finalSvg], { type: "image/svg+xml" });
  const bitmap = await createImageBitmap(svgBlob);

  const canvas = document.createElement("canvas");
  canvas.width = 1200;
  canvas.height = 630;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0);

  const pngBlob = await canvas.toBlob();
  return await pngBlob.arrayBuffer();
}

generateOGImage();
