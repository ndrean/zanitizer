async function runTest() {
  console.log("\nStarting WritableStream Test \n");
  const filename = "test_output.txt";

  try {
    // - Cleanup previous run
    try {
      await fs.rm(filename);
    } catch (e) {}

    // - Create Stream & Writer
    console.log("\nCreating WriteStream \n");
    const stream = fs.createWriteStream(filename);
    const writer = stream.getWriter();

    // - Test Property access
    console.log(`Desired Size: ${writer.desiredSize}`);
    // Should be high (e.g. 64KB)
    console.log(`Ready State: ${await writer.ready}`);

    // - Write String (TextEncoder implicit or explicit depending on implementation)
    console.log("Writing String...");
    await writer.write("Hello from Zig Runtime! \n");

    // - Write Binary (Uint8Array)
    console.log("\nWriting Binary Data.\n");
    const binaryData = new Uint8Array([65, 66, 67, 68]); // ABCD
    await writer.write(binaryData);
    await writer.write("\n");

    // - Stress Test (Queuing)
    // fire multiple writes without awaiting immediately
    // test internal queue
    console.log("\nTesting Queue/Backpressure\ n");
    const promises = [];
    for (let i = 0; i < 5; i++) {
      promises.push(writer.write(`Line ${i}\n`));
    }
    await Promise.all(promises);

    // - Close
    console.log("🔒 Closing stream...");
    await writer.close();

    // - Verification (Read back)
    console.log("🔍 Verifying content...");
    const content = await fs.readFile(filename);

    console.log("--- FILE CONTENT START ---");
    console.log(content);
    console.log("--- FILE CONTENT END ---");

    if (content.includes("ABCD") && content.includes("Line 4")) {
      console.log("✅ TEST PASSED: Content matches expected output.");
    } else {
      console.error("❌ TEST FAILED: Content mismatch.");
    }
  } catch (err) {
    console.error("❌ CRITICAL ERROR:", err);
  }
}
runTest();
