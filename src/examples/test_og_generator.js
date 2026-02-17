// fetch an image and convert it to Base64 for SVG embedding
// async function fetchAsBase64(url) {
//   const res = await fetch(url);
//   const arrayBuffer = await res.arrayBuffer();
//   console.log(arrayBuffer.byteLength);
//   console.log(res.headers.get("content-type"));

//   // to base64
//   const uint8Array = new Uint8Array(arrayBuffer);
//   let binaryString = "";
//   for (let i = 0; i < uint8Array.length; i++) {
//     binaryString += String.fromCharCode(uint8Array[i]);
//   }
//   return `data:${res.headers.get("content-type") || "image/png"};base64,${btoa(binaryString)}`;
// }

async function loadImage(url) {
  return await new Promise((resolve, reject) => {
    try {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = (e) => reject(new Error(`Image failed to load: ${url}`));
      img.src = url;
    } catch (e) {
      reject(new Error(`Failed to fetch image: ${e.message}`));
    }
  });
}

async function generateOGImage({ title, author, avatarUrl }) {
  console.log(`Generating OG Image for:  ${title}`);
  const avatarImg = await loadImage(avatarUrl);

  const templ_res = await fetch(
    "file://src/examples/test_og_generator_template_v2.svg",
  );

  const rawSvgTemplate = await templ_res.text();
  const finalSvgText = rawSvgTemplate
    .replace("{{TITLE}}", title)
    .replace("{{AUTHOR}}", author);
  const svgBlob = new Blob([finalSvgText], { type: "image/svg+xml" });
  const imgSVG = await createImageBitmap(svgBlob);

  const canvas = document.createElement("canvas");
  canvas.width = 1200;
  canvas.height = 630;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(avatarImg, 100, 100, 150, 150); // in the hole
  ctx.drawImage(imgSVG, 0, 0);

  const pngBlob = await canvas.toBlob();
  return await pngBlob.arrayBuffer();
}

async function renderTemplate() {
  try {
    console.log("Called");
    const pngBytes = await generateOGImage({
      title: "Headless Browser in Zig",
      author: "N. Drean",
      avatarUrl: "https://github.com/torvalds.png",
    });

    // FileSystem call writeFile("./out/og-image.png", new Uint8Array(pngBytes)) or Zig?
    return pngBytes;
  } catch (e) {
    console.error("Failed to generate OG image:", e);
  }
}

// async function testFetch() {
//   const res = await fetch("file://src/examples/test_og_generator_template.svg");
//   const text = await res.text();
//   console.log("SVG length:", text.length);
//   console.log("First 100 chars:", text.substring(0, 100));
//   return text;
// }
