const changeText = () => {
  const p = document.getElementById("pid");
  p.textContent = "New text";
};

const btn = document.querySelector("button");
btn.addEventListener("click", () => {
  changeText();
});

btn.dispatchEvent(new Event("click"), (e) => {
  console.log("Button clicked");
});
