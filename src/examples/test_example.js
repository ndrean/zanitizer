// Test 1: insertAdjacentHTML("beforeend")
const html1 = `<p id="js1" class="untrusted" style="padding: 8px; behavior: url(evil.htc);">insertAdjacentHTML</p>`;
document.body.insertAdjacentHTML("beforeend", html1);

// Test 2: innerHTML on a container div
const container = document.createElement("div");
container.id = "container2";
document.body.appendChild(container);
container.innerHTML = `<p id="js2" class="untrusted" style="padding: 8px; behavior: url(evil2.htc);">innerHTML</p>`;

// Test 3: outerHTML replacement
const placeholder = document.createElement("span");
placeholder.id = "placeholder3";
document.body.appendChild(placeholder);
placeholder.outerHTML = `<p id="js3" class="untrusted" style="padding: 8px; behavior: url(evil3.htc);">outerHTML</p>`;

// Test 4: insertAdjacentHTML("afterbegin") on body
document.body.insertAdjacentHTML(
  "afterbegin",
  `<p id="js4" class="untrusted" style="padding: 8px; behavior: url(evil4.htc);">afterbegin</p>`,
);

// Test 5: createElement + setAttribute + appendChild
const p = document.createElement("p");
p.id = "js5";
p.className = "untrusted";
p.setAttribute("style", "background: url(evil5.htc); padding: 8px;");
document.body.appendChild(p);

// Test 6: template with evil content, cloned and appended
const tmpl = document.createElement("template");
tmpl.innerHTML = `<p id="js6" class="untrusted" style="padding: 8px; behavior: url(evil6.htc);">template clone</p>`;
const clone = tmpl.content.cloneNode(true);
document.body.appendChild(clone);

// Test 7: replaceChildren on a placeholder container
const box7 = document.createElement("div");
box7.id = "box7";
document.body.appendChild(box7);
const p7 = document.createElement("p");
p7.id = "js7";
p7.className = "untrusted";
p7.setAttribute("style", "background: url(evil7.htc); padding: 8px;");
p7.textContent = "replaceChildren";
box7.replaceChildren(p7);

// Test 8: replaceWith on a placeholder span
const ph8 = document.createElement("span");
ph8.id = "ph8";
document.body.appendChild(ph8);
const p8 = document.createElement("p");
p8.id = "js8";
p8.className = "untrusted";
p8.setAttribute("style", "background: url(evil8.htc); padding: 8px;");
p8.textContent = "replaceWith";
ph8.replaceWith(p8);
