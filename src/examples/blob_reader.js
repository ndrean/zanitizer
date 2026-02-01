console.log("=== Memory Blob Test (RAM Only) ===");

function testBlob() {
  // 1. Create a pure Memory Blob
  // This lives 100% in RAM. No "path" option used.
  const textContent = "Hello Zig Worker! ⚡️";
  const blob = new Blob([textContent], { type: "text/plain" });

  console.log(`[JS] Created Blob. Size: ${blob.size}`);

  const reader = new FileReader();

  reader.onload = () => {
    console.log("[JS] onload fired!");

    const result = reader.result;
    console.log("   Result:", result);

    // Expected: data:text/plain;base64,SGVsbG8gWmlnIFdvcmtlciEg4pqh77iP
    if (result.startsWith("data:text/plain;base64,")) {
      console.log("✅ SUCCESS: Encoded as DataURL");
    } else {
      console.log("❌ FAIL: Unexpected format");
    }
  };

  reader.onerror = () => {
    console.log("❌ Error:", reader.error);
  };

  // 2. Trigger the Worker
  console.log("[JS] Starting readAsDataURL...");
  reader.readAsDataURL(blob);
}

testBlob();
