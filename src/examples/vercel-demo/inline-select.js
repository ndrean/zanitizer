async function select() {
  await zxp.goto("https://demo.vercel.store");
  await zxp.waitForSelector("a[href^='/product/']");

  const links = document.querySelectorAll("a[href^='/product/']");
  const unique = [
    ...new Set(Array.from(links).map((el) => el.getAttribute("href"))),
  ];
  const items = unique.map((href) => {
    const el = document.querySelector(`a[href='${href}']`);
    return el.textContent.trim();
  });
  return items;
}

select();
