async function run() {
  const html = await zxp.llmHTML({
    model: "llama3.1",
    prompt: "desgin 3 metric cards in a row using flexbox with inner contents: 'Revenue $12k', 'Users 340', 'Uptime 99.9%'. White background color, colored cards.",
  });

  document.body.innerHTML = html;
  const img = zxp.paintDOM(document.body, 800);
  return zxp.encode(img, "webp");
  // zxp.save(img, "src/examples/generative/test_llm.webp");
}
run();