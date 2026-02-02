let start = performance.now();
const NB = globalThis.NB;
console.log(`Starting DOM creation test with ${NB} elements`);
const btn = document.createElement("button");
const form = document.createElement("form");
form.appendChild(btn);
document.body.appendChild(form);

const mylist = document.createElement("ul");

for (let i = 1; i <= parseInt(NB); i++) {
  const item = document.createElement("li");
  item.textContent = "Item " + i * 10;
  item.setAttribute("id", i.toString());
  mylist.appendChild(item);
}
document.body.appendChild(mylist);

let time = performance.now() - start;

const lis = document.querySelectorAll("li");
console.log(lis.length);

start = performance.now();
let clickCount = 0;
btn.addEventListener("click", () => {
  clickCount++;
  btn.textContent = `Clicked ${clickCount}`
});

// Simulate clicks
for (let i = 0; i < parseInt(NB); i++) {
  btn.dispatchEvent("click");
}



time = performance.now() - start;

console.log(
  JSON.stringify({{
    time: time,
    elementCount: lis.length,
    last_li_id: lis[lis.length - 1].getAttribute("id"),
    last_li_text: lis[lis.length - 1].textContent,
    success: clickCount === parseInt(NB),
  }}),
);

