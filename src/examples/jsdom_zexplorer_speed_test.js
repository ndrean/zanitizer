let start = performance.now();
const NB = 30_000;

const btn = document.createElement("button");
const form = document.createElement("form");
form.appendChild(btn);
document.body.appendChild(form);

const mylist = document.createElement("ul");

for (let i = 1; i < NB; i++) {
  const item = document.createElement("li");
  item.textContent = "Item " + i * 10;
  item.setAttribute("id", i.toString());
  mylist.appendChild(item);
}
document.body.appendChild(mylist);

let time = performance.now() - start;

console.log(
  JSON.stringify({
    test: "dom_creation",
    time: time,
    elementCount: document.querySelectorAll("*").length,
    success: true,
  }),
);

start = performance.now();
let clickCount = 0;
btn.addEventListener("click", () => {
  clickCount++;
  // btn.setTextContentAsText(`Clicked ${clickCount}`);
});

// Simulate clicks
for (let i = 0; i < 30_000; i++) {
  btn.dispatchEvent("click");
}

time = performance.now() - start;

console.log(
  JSON.stringify({
    test: "event_system",
    time: time,
    clicks: clickCount,
    // finalText: btn.textContent(),
    success: clickCount === 30000,
  }),
);
