// chunk_post.js
// Splits an HTML file into chunks and streams them to stdout one at a time,
// simulating a chunked HTTP response for the `zxp stream` pipeline.
//
// Usage:
//   ./zig-out/bin/zxp run src/examples/chunk_post.js \
//     | ./zig-out/bin/zxp stream \
//     | ./zig-out/bin/zxp sanitize - \
//     | ./zig-out/bin/zxp convert - -o pipeline.png

const SOURCE =
  zxp.flags.file || "file://src/examples/test_stream_pipeline.html";
const CHUNK_SIZE = parseInt(zxp.flags.chunk || "512", 10);
const DELAY_MS = parseInt(zxp.flags.delay || "5", 10);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function stream() {
  const html = await fetch(SOURCE).then((r) => r.text());

  const chunks = [];
  for (let i = 0; i < html.length; i += CHUNK_SIZE) {
    chunks.push(html.slice(i, i + CHUNK_SIZE));
  }

  console.error(
    `[chunker] ${html.length} bytes → ${chunks.length} chunks of ${CHUNK_SIZE}b`,
  );

  for (let i = 0; i < chunks.length; i++) {
    zxp.write(chunks[i]);
    await sleep(DELAY_MS);
  }

  console.error(`[chunker] done`);
}

stream();
