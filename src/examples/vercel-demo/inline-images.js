// Inline external images as base64 data URIs using native parallel fetchAll().
// Resolves Next.js srcset URLs; removes srcset after inlining.
async function fetchImages() {
  const base = "https://demo.vercel.store";
  const imgs = Array.from(document.querySelectorAll("img"));

  // Collect one URL per image (first srcset entry preferred over src).
  const urls = imgs.map((img) => {
    const srcset = img.getAttribute("srcset");
    if (srcset) {
      const first = srcset.split(",")[0].trim().split(/\s+/)[0];
      if (first) return first.startsWith("http") ? first : base + first;
    }
    const src = img.getAttribute("src");
    if (src && !src.startsWith("data:")) {
      return src.startsWith("http") ? src : base + src;
    }
    return null;
  });

  // Fetch all in parallel via libcurl multi.
  const results = fetchAll(
    urls.filter((u) => u !== null),
    {
      Accept: "image/png,image/jpeg,image/webp,*/*;q=0.5",
      Referer: base + "/",
    },
  );
  // console.log(results);

  // Map results back to images (skip nulls).
  let ri = 0;
  for (let i = 0; i < imgs.length; i++) {
    if (urls[i] === null) continue;
    const r = results[ri++];
    if (!r || !r.ok) continue;
    imgs[i].setAttribute("src", arrayBufferToBase64DataUri(r.data, r.type));
    imgs[i].removeAttribute("srcset");
  }

  return document.documentElement.outerHTML;
}
fetchImages();
