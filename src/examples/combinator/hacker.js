async function scrape() {
  url = "https://news.ycombinator.com/newest";
  await zxp.goto(url);
  return Array.from(document.querySelectorAll(".titleline a")).map((a) => [
    a.textContent,
    a.href,
  ]);
}

scrape();
