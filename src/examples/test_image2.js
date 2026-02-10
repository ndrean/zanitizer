// Fetch a JPEG from the network, tile it on a canvas, export as PNG
async function draw() {
  const canvas = document.createElement("canvas");
  canvas.id = "canvas";
  canvas.width = 600;
  canvas.height = 800;
  document.body.appendChild(canvas);
  const ctx = canvas.getContext("2d");

  const img = await new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = (e) => reject("Image failed to load");
    img.src = "https://mdn.github.io/shared-assets/images/examples/rhino.jpg";
  });

  console.log("Image loaded:", img.width, "x", img.height);

  for (let i = 0; i < 4; i++) {
    for (let j = 0; j < 3; j++) {
      ctx.drawImage(img, j * 50, i * 38, 50, 38);
    }
  }

  const blob = await canvas.toBlob();
  return await blob.arrayBuffer();
}

draw();
