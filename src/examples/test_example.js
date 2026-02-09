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
document.body.insertAdjacentHTML("afterbegin",
  `<p id="js4" class="untrusted" style="padding: 8px; behavior: url(evil4.htc);">afterbegin</p>`);
