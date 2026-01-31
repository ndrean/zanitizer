async function runStreamingTest() {
  const FILE_NAME = "big_upload_test.dat";
  const FILE_SIZE_MB = 1;
  const CHUNK_SIZE = 64 * 1024;
  const UPLOAD_URL = "https://httpbin.org/post";
  console.log(`\n🚀 STARTING STREAMING UPLOAD TEST (${FILE_SIZE_MB}MB)`);

  try {
    console.log(
      `\n[1/3] 💿 Generating ${FILE_SIZE_MB}MB file: "${FILE_NAME}"\n`,
    );
    const writeStream = fs.createWriteStream(FILE_NAME);
    const writer = writeStream.getWriter();
    const totalBytes = FILE_SIZE_MB * 1024 * 1024;
    const chunk = new Uint8Array(CHUNK_SIZE).fill(88); // Fill with 'X'
    let written = 0;
    const startWrite = Date.now();
    while (written < totalBytes) {
      // (async write in Worker thread)
      await writer.write(chunk);
      written += CHUNK_SIZE;
    }
    await writer.close();
    const writeTime = (Date.now() - startWrite) / 1000;
    console.log(
      `\n✅ ${writeTime.toFixed(2)}s: (${(FILE_SIZE_MB / writeTime).toFixed(2)}MB/s)`,
    );

    console.log(`\n[2/3] 📦 Preparing Zero-Copy FormData...`);

    const form = new FormData();
    const diskFile = fs.fileFromPath(FILE_NAME);
    console.log(`   -> File Size on Disk: ${diskFile.size}`);
    console.log(`   -> File Path: ${FILE_NAME}`);
    form.append("media", diskFile);
    form.append("description", "Large streaming upload test");

    console.log(`\n[3/3] 🌍 Uploading to ${UPLOAD_URL}...`);

    const startUpload = Date.now();

    const res = await fetch(UPLOAD_URL, {
      method: "POST",
      body: form,
    });
    const uploadTime = (Date.now() - startUpload) / 1000;
    console.log(`📦 Status: ${res.status} ${res.statusText}`);

    const json = await res.json();
    if (json.files && json.files.media) {
      console.log(`✅ Server received file!`);
      // console.log(`   (Server size preview: ${json.files.media.length} chars)`);
    } else {
      console.log(
        `⚠️  Server didn't report the file (Size might be too big for HttpBin response)`,
      );
    }
    console.log(`🚀 Upload finished in ${uploadTime.toFixed(2)}s`);
    // await fs.rm(FILE_NAME);
  } catch (err) {
    console.error("\n❌ TEST FAILED:", err);
  }
}
runStreamingTest();
