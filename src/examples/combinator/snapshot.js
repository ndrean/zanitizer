async function snap() {
  url = "https://news.ycombinator.com/newest";
  await zxp.goto(url);
  const img = zxp.paintDOM(document.body);
  zxp.save(img, "src/examples/combinator/hacker.webp");
}

snap();