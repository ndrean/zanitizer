// ============================================================
// HTMX Benchmark — Direct DOM swap
//
// Simulates what HTMX does: server returns HTML fragments,
// client parses and swaps them into the DOM via innerHTML.
// No HTMX library needed — measures raw DOM manipulation speed.
// ============================================================

// --- Server-side state ---

const adjectives = [
  "pretty", "large", "big", "small", "tall", "short", "long", "handsome",
  "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful",
  "mushy", "odd", "unsightly", "adorable", "important", "inexpensive",
  "cheap", "expensive", "fancy",
];
const colours = [
  "red", "yellow", "blue", "green", "pink", "brown", "purple", "brown",
  "white", "black", "orange",
];
const nouns = [
  "table", "chair", "house", "bbq", "desk", "car", "pony", "cookie",
  "sandwich", "burger", "pizza", "mouse", "keyboard",
];

let data = [];
let nextId = 1;
let selectedRowId = null;

function generateLabel() {
  return `${adjectives[Math.floor(Math.random() * 1000) % adjectives.length]} ${colours[Math.floor(Math.random() * 1000) % colours.length]} ${nouns[Math.floor(Math.random() * 1000) % nouns.length]}`;
}

function rowHTML(id, label, selected) {
  const cls = selected ? ' class="danger"' : "";
  return `<tr${cls} data-id="${id}">` +
    `<td class="col-md-1">${id}</td>` +
    `<td class="col-md-4"><a class="lbl">${label}</a></td>` +
    `<td class="col-md-1"><a class="remove">` +
    `<span class="remove glyphicon glyphicon-remove" aria-hidden="true"></span></a></td>` +
    `<td class="col-md-6"></td></tr>`;
}

function allRowsHTML() {
  let html = "";
  for (let i = 0; i < data.length; i++) {
    html += rowHTML(data[i].id, data[i].label, data[i].id === selectedRowId);
  }
  return html;
}

// --- Operations (generate HTML + swap into DOM, like HTMX would) ---

const tbody = document.getElementById("tbody");

function create(count) {
  data = [];
  selectedRowId = null;
  for (let i = 0; i < count; i++) {
    data.push({ id: nextId++, label: generateLabel() });
  }
  tbody.innerHTML = allRowsHTML();
}

function append(count) {
  for (let i = 0; i < count; i++) {
    data.push({ id: nextId++, label: generateLabel() });
  }
  tbody.innerHTML = allRowsHTML();
}

function update() {
  for (let i = 0; i < data.length; i += 10) {
    data[i].label += " !!!";
  }
  selectedRowId = null;
  tbody.innerHTML = allRowsHTML();
}

function clear() {
  data = [];
  selectedRowId = null;
  tbody.innerHTML = "";
}

function swapRows() {
  if (data.length > 998) {
    const tmp = data[1];
    data[1] = data[998];
    data[998] = tmp;
  }
  selectedRowId = null;
  tbody.innerHTML = allRowsHTML();
}

function selectRow(nthChild) {
  const row = tbody.querySelector(`tr:nth-child(${nthChild})`);
  if (!row) { console.log("❌ No row at position " + nthChild); return; }
  const id = parseInt(row.getAttribute("data-id"));
  selectedRowId = selectedRowId === id ? null : id;
  row.setAttribute("class", selectedRowId === id ? "danger" : "");
}

function removeRow(nthChild) {
  const row = tbody.querySelector(`tr:nth-child(${nthChild})`);
  if (!row) { console.log("❌ No row at position " + nthChild); return; }
  const id = parseInt(row.getAttribute("data-id"));
  const idx = data.findIndex((d) => d.id === id);
  if (idx !== -1) data.splice(idx, 1);
  if (selectedRowId === id) selectedRowId = null;
  row.remove();
}

// --- Benchmark Suite ---

function measure(name, fn) {
  const start = performance.now();
  fn();
  const end = performance.now();
  console.log(`[${name}] ${(end - start).toFixed(2)} ms`);
}

console.log("\n🚀 Starting HTMX Benchmark\n");

// Create 1,000 rows
measure("Create 1k", () => create(1000));

// Replace all rows
measure("Replace 1k", () => create(1000));

// Partial Update (setup 10k first)
create(10000);
measure("Partial Update (10k)", () => update());

// Select Row
measure("Select Row", () => selectRow(2));

// Swap Rows (reset to 1k first)
create(1000);
measure("Swap Rows", () => swapRows());

// Remove Row
measure("Remove Row", () => removeRow(2));

// Create 10,000 Rows
measure("Create 10k", () => create(10000));

// Append 1,000 Rows
measure("Append 1k", () => append(1000));

// Clear Rows
measure("Clear", () => clear());

// Sanity check
const count = document.querySelectorAll("tbody tr").length;
if (count !== 0) console.log(`❌ Leaked Rows: ${count}`);
else console.log(`✅ Clean Run`);
