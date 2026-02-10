// a 1x1 fully opaque red pixel (RGBA 255,0,0,255)
const red_pixel_b64 =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";

const renderRedPixel = new Promise((resolve, reject) => {
  const img = new Image();

  img.onload = function () {
    try {
      if (this.width !== 1 || this.height !== 1) {
        reject("Wrong dimensions: " + this.width + "x" + this.height);
        return;
      }

      const canvas = document.createElement("canvas");
      canvas.width = 1;
      canvas.height = 1;
      const ctx = canvas.getContext("2d");

      ctx.drawImage(this, 0, 0);

      // 3. Check Pixel Color (Should be Red)
      const pixels = ctx.getImageData(0, 0, 1, 1).data;
      // R=255, G=0, B=0, A=255
      if (
        pixels[0] === 255 &&
        pixels[1] === 0 &&
        pixels[2] === 0 &&
        pixels[3] === 255
      ) {
        resolve("SUCCESS");
      } else {
        reject("Wrong color: " + pixels[0] + "," + pixels[1] + "," + pixels[2]);
      }
    } catch (e) {
      reject(e.toString());
    }
  };

  img.onerror = (e) => reject("Image failed to load");

  // Trigger the load
  img.src = red_pixel_b64;
});

renderRedPixel.catch((e) => {
  console.log("render error:", e);
  throw e;
});
