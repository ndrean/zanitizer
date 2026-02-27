// Smoke test: bidirectional Markdown ↔ HTML conversion
//
// Pipeline A — Markdown → HTML (md4c, native, GFM):
//   const html = zxp.markdownToHTML(md);
//
// Pipeline B — HTML → Markdown (turndown.js, DOM walk):
//   const md = zxp.toMarkdown(element);
//
// Full round-trip: MD → HTML → lexbor → render PNG:
//   ./zig-out/bin/zxp run src/examples/generative/test_markdown.js \
//     | ./zig-out/bin/zxp convert - -o /tmp/md_test.png

// --- Pipeline A: Markdown → HTML -----------------------------------------

const md = `# Hello from Markdown

This is **GFM** rendered natively via md4c.

| Column A | Column B |
|----------|----------|
| foo      | bar      |
| baz      | qux      |

- [x] md4c parses GFM Markdown
- [x] lexbor renders the resulting HTML
- [ ] profit

~~Strikethrough~~, https://example.com autolink, and <span style="color:red">raw HTML</span> all pass through.
`;

const html = zxp.markdownToHTML(md);

// --- Pipeline B: HTML → Markdown (DOM walk via turndown) ------------------

zxp.loadHTML(`<html><body>
  <h2>DOM to Markdown</h2>
  <p>A paragraph with <strong>bold</strong> and <em>italic</em> text.</p>
  <ul><li>Item A</li><li>Item B</li></ul>
</body></html>`);

const mdFromDOM = zxp.toMarkdown(document.body);
console.error("toMarkdown output:\n" + mdFromDOM);

// --- Output full page for `convert` pipe ----------------------------------

const page = `<html><head><style>
  body { font-family: sans-serif; padding: 24px; max-width: 640px; }
  h1, h2 { color: #1a1a2e; }
  table { border-collapse: collapse; width: 100%; margin: 12px 0; }
  td, th { border: 1px solid #ccc; padding: 8px 12px; }
  th { background: #f5f5f5; font-weight: 600; }
  .task-list-item { list-style: none; margin-left: -20px; }
  del { color: #888; }
</style></head><body>${html}</body></html>`;

console.log(page);
