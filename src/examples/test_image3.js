// Fetch a JPEG from the network, tile it on a canvas, export as PNG
const url = "https://mdn.github.io/shared-assets/images/examples/rhino.jpg";

async function draw() {
  const canvas = document.createElement("canvas");
  canvas.id = "canvas";
  canvas.width = 300;
  canvas.height = 200;
  document.body.appendChild(canvas);
  const ctx = canvas.getContext("2d");

  const img = await new Promise(async (resolve, reject) => {
    try {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = (e) => reject(new Error("Image failed to load"));

      img.src = url;
    } catch (e) {
      reject(new Error(`Failed to fetch image: ${e.message}`));
    }
  });

  console.log("Image loaded:", img.width, "x", img.height);

  for (let i = 0; i < 2; i++) {
    for (let j = 0; j < 2; j++) {
      ctx.drawImage(img, j * 50, i * 38, 50, 38);
    }
  }

  return canvas.toBlob().then(async (blob) => {
    console.log("Output blob size:", blob.size);
    return await blob.arrayBuffer();
  });
}

draw();
