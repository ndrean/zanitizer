const changeText = () => {
  const p = document.getElementById("pid");
  p.textContent = "New text";
};

const btn = document.querySelector("button");

btn.addEventListener("click", () => {
  console.log("[JS] Button clicked"); // <--- Moved inside

  changeText();

  // Inspect the DOM *after* change
  const p = document.getElementById("pid");
  console.log("[JS] 'p' text content: ", p.textContent);

  // Inspect styles
  const computed = window.getComputedStyle(p);
  // Note: p.style.getPropertyValue only reads INLINE styles.
  // Use getComputedStyle for CSS-in-JS/External CSS resolution.
  const p_color = computed.getPropertyValue("color");
  const p_fontSize = computed.getPropertyValue("font-size");

  const p_css_color = window.getComputedStyle(p).getPropertyValue("color");

  console.log("[JS] 'p' color: ", p_color);
  console.log("[JS] 'p' CSS color: ", p_css_color);
  console.log("[JS] 'p' font size: ", p_fontSize);
});

btn.dispatchEvent(new Event("click"));
