function previewFile(input) {
  const img = document.querySelector("img");
  const file = new File([], "file_reader.png", {
    path: "src/examples/file_reader.png",
    type: "image/png",
  });
  console.log(`[JS] : ${file.size}`);
  const reader = new FileReader();

  reader.onload = () => {
    // () => {
    console.log("[JS] onload");
    const result = reader.result;
    console.log("📸 Image Preview Ready!");
    console.log("   Src:", result.substring(0, 50) + "...");
  };

  if (file) {
    console.log(`📂 Reading: ${file.name}`);
    reader.readAsDataURL(file);
  }
}

const input = document.querySelector("input");
previewFile(input);
