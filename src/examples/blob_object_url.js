async function test() {
  try {
    const content = "Hello Zig Blob!";
    const mime = "text/plain";
    console.log("[JS] Creating Blob...");
    const blob = new Blob([content], { type: mime });

    const url = URL.createObjectURL(blob);
    console.log("[JS] ObjectURL from Blob: ", url);

    console.log("[JS] Fetching.ObjectURL..");
    const res = await fetch(url);
    console.log("[JS] response:", res);

    console.log("[JS] StatusText:", res.statusText);
    if (!res.ok) throw new Error("Response not OK");

    // Note: Real fetch uses res.headers.get(), but we returned a plain object
    const type = res.headers["Content-Type"];
    console.log("[JS] Content-Type:", type);
    if (type !== mime) throw new Error("Wrong Mime Type");

    const text = await res.text();
    console.log("[JS] Body:", text);
    if (text !== content) throw new Error("Body mismatch");

    // JSON Test
    const jsonBlob = new Blob([JSON.stringify({ size: 123 })], {
      type: "application/json",
    });
    const jsonUrl = URL.createObjectURL(jsonBlob);
    const jsonRes = await fetch(jsonUrl);
    console.log(jsonRes);

    const jsonObj = await jsonRes.text();
    console.log("[JS] JSON Prop:", jsonObj);
    const obj = JSON.parse(jsonObj);

    console.log("[JS] JSON Prop:", obj.size);
    if (obj.size !== 123) throw new Error("JSON mismatch");

    URL.revokeObjectURL(url);
    URL.revokeObjectURL(jsonUrl);
    console.log("[JS] ✅ All checks passed");

    const tagRE =
      /(?:<!--[\S\s]*?-->|<(?:"[^"]*"['"]*|'[^']*'['"]*|[^'">])+>)/g;

    const html = `<div class="some-class" data-value="test">`;

    const arr = tagRE.exec(html);
    console.log("[JS] RegExp Test:", arr);
  } catch (e) {
    console.log("[JS] ❌ ERROR:", e.message || e);
  }
}

test();
