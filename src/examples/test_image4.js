async function draw() {
  const canvas = document.createElement("canvas");
  canvas.width = 300;
  canvas.height = 227;
  document.body.appendChild(canvas);
  const ctx = canvas.getContext("2d");

  // Read local file → Blob → objectURL → img.src
  const buffer = await fs.readFileBuffer("images/rhino.jpg");
  const blob = new Blob([buffer], { type: "image/jpeg" });
  const url = URL.createObjectURL(blob);

  const img = await new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject("Failed to load");
    img.src = url; // blob: path — already works!
  });

  ctx.drawImage(img, 0, 0);
  URL.revokeObjectURL(url);

  const out = await canvas.toBlob();
  return await out.arrayBuffer();
}
draw();
