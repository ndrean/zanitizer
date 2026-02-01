async function testFS() {
  const testDir = "/tmp/zexplorer_fs_test";
  const testFile = testDir + "/test.txt";
  const testFile2 = testDir + "/test_copy.txt";
  const testFile3 = testDir + "/test_renamed.txt";
  const binaryFile = testDir + "/binary.bin";

  // ============================================================
  console.log("=== fs.exists() \n");
  const exists1 = await fs.exists("build.zig");
  console.log("build.zig exists:", exists1.exists);

  const exists2 = await fs.exists("nonexistent_file.xyz");
  console.log("nonexistent_file.xyz exists:", exists2.exists);

  // ============================================================
  console.log("\n=== fs.stat() \n");
  const stat = await fs.stat("build.zig");
  console.log("build.zig stat:");
  console.log("  size:", stat.size, "bytes");
  console.log("  mtime:", new Date(stat.mtime).toISOString());
  console.log("  isFile:", stat.isFile);
  console.log("  isDirectory:", stat.isDirectory);

  const dirStat = await fs.stat("src");
  console.log("src/ stat:");
  console.log("  isFile:", dirStat.isFile);
  console.log("  isDirectory:", dirStat.isDirectory);

  // ============================================================
  console.log("\n=== fs.readDir() \n");
  const result = await fs.readDir("src/examples");
  console.log("src/examples/ contents:");
  for (const entry of result.entries.slice(0, 5)) {
    const type = entry.isDirectory ? "[DIR]" : "[FILE]";
    console.log("  " + type, entry.name);
  }
  if (result.entries.length > 5) {
    console.log("  ... and", result.entries.length - 5, "more");
  }

  // ============================================================
  console.log("\n=== fs.mkdir() \n");
  // Clean up from previous runs
  try {
    await fs.rm(testDir);
    console.log("Cleaned up previous test directory");
  } catch (e) {
    // Directory didn't exist, that's fine
  }

  await fs.mkdir(testDir);
  const dirExists = await fs.exists(testDir);
  console.log("Created", testDir, "- exists:", dirExists.exists);

  // ============================================================
  console.log("\n=== fs.writeFile() \n");
  await fs.writeFile(testFile, "Hello from Zig + QuickJS!\n");
  const content = await fs.readFile(testFile);
  console.log("Wrote and read back:", JSON.stringify(content));

  // ============================================================
  console.log("\n=== fs.appendFile() ");
  await fs.appendFile(testFile, "This line was appended.\n");
  await fs.appendFile(testFile, "And another one!\n");
  const appended = await fs.readFile(testFile);
  console.log("After append:");
  console.log(appended);

  // ============================================================
  console.log("=== fs.readFileBuffer() \n");
  // Write some binary data - pass ArrayBuffer, not Uint8Array
  const binaryData = new Uint8Array([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  ]); // PNG header
  await fs.writeFile(binaryFile, binaryData.buffer);

  const buffer = await fs.readFileBuffer(binaryFile);
  console.log("Read binary file as ArrayBuffer:");
  console.log("  Type:", buffer.constructor.name);
  console.log("  Length:", buffer.byteLength, "bytes");
  const view = new Uint8Array(buffer);
  console.log(
    "  First 4 bytes:",
    view[0].toString(16),
    view[1].toString(16),
    view[2].toString(16),
    view[3].toString(16),
  );

  // ============================================================
  console.log("\n=== fs.copyFile() \n");
  await fs.copyFile(testFile, testFile2);
  const copied = await fs.readFile(testFile2);
  console.log("Copied file contents match:", copied === appended);

  // ============================================================
  console.log("\n=== fs.rename() \n");
  await fs.rename(testFile2, testFile3);
  const renamedExists = await fs.exists(testFile3);
  const oldExists = await fs.exists(testFile2);
  console.log("Renamed file exists:", renamedExists.exists);
  console.log("Old file exists:", oldExists.exists);

  // ============================================================
  console.log("\n=== fs.fileFromPath() \n");
  const file = fs.fileFromPath(testFile);
  console.log("File object created:");
  console.log("  name:", file.name);
  console.log("  size:", file.size, "bytes");
  console.log("  type:", file.type);
  console.log("  lastModified:", new Date(file.lastModified).toISOString());

  // ============================================================
  console.log("\n=== fs.createReadStream() \n");
  console.log("Streaming build.zig...");
  const stream = fs.createReadStream("build.zig");
  console.log("  Stream created, locked:", stream.locked);

  const reader = stream.getReader();
  console.log("  Reader obtained, stream locked:", stream.locked);

  let totalBytes = 0;
  let chunks = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    chunks++;
    totalBytes += value.length;
    if (chunks <= 3) {
      console.log("  Chunk", chunks + ":", value.length, "bytes");
    }
  }
  if (chunks > 3) {
    console.log("  ... and", chunks - 3, "more chunks");
  }
  console.log("  Total:", totalBytes, "bytes in", chunks, "chunk(s)");

  // ============================================================
  console.log("\n=== fs.createWriteStream() \n");
  const streamFile = testDir + "/streamed.txt";
  console.log("Creating write stream to", streamFile);
  const wstream = fs.createWriteStream(streamFile);
  const wwriter = wstream.getWriter();

  const encoder = new TextEncoder();
  await wwriter.write(encoder.encode("Line 1\n"));
  await wwriter.write(encoder.encode("Line 2\n"));
  await wwriter.write(encoder.encode("Line 3\n"));
  await wwriter.close();

  const streamedContent = await fs.readFile(streamFile);
  console.log("Streamed content:");
  console.log(streamedContent);

  // ============================================================
  console.log("=== fs.rm() \n");
  await fs.rm(testDir);
  const removed = await fs.exists(testDir);
  console.log("Removed test directory - exists:", removed.exists);

  // ============================================================
  console.log("\n========================================");
  console.log("🟢 All fs tests completed successfully!");
}

testFS().catch((e) => console.log("Error:", e.message || e));
