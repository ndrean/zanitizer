async function testReadableStream() {
  console.log("--- Fetching data ---");
  const response = await fetch("https://httpbin.org/get");
  console.log("Status:", response.status);
  console.log("OK:", response.ok);

  console.log("\n--- Testing response.body ---");
  console.log("response.body:", response.body);
  console.log("typeof response.body:", typeof response.body);

  // Test locked property
  console.log("response.body.locked:", response.body.locked);

  // Get a reader
  console.log("\n--- Getting reader ---");
  const reader = response.body.getReader();
  console.log("reader:", reader);
  console.log("response.body.locked after getReader():", response.body.locked);

  // Read chunks
  console.log("\n--- Reading chunks ---");
  let chunks = [];
  let totalBytes = 0;

  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      console.log("Stream done!");
      break;
    }
    console.log(
      "Chunk received:",
      value.constructor.name,
      "length:",
      value.length,
    );
    chunks.push(value);
    totalBytes += value.length;
  }

  console.log("\n--- Summary ---");
  console.log("Total chunks:", chunks.length);
  console.log("Total bytes:", totalBytes);

  // Decode the data
  console.log("\n--- Decoding ---");
  const decoder = new TextDecoder();
  let fullText = "";
  for (const chunk of chunks) {
    fullText += decoder.decode(chunk);
  }
  console.log("Decoded text length:", fullText.length);
  console.log("First 100 chars:", fullText.substring(0, 100));

  // Parse as JSON to verify
  const data = JSON.parse(fullText);
  console.log("\n--- Parsed JSON ---");
  console.log("url:", data.url);
  console.log("origin:", data.origin);

  console.log("\n🟢 ReadableStream test passed");
}

testReadableStream().catch((e) => console.log("❌ Error:", e.message || e));
