import Bau from "vendor/bau";

// async function run() {
// const res = await fetch("file://src/examples/vendor/bau.js");
// const src = await res.text();
// eval(src);
// zxp.fs.writeFileSync("src/examples/vendor/bau.js", src);

  // const html = "<html><body><div id='app'></div><script src='src/examples/vendor/bau.js'></script></body></html>";
  

  // zxp.loadHTML(html);
  // await zxp.runScripts();
  // console.log(globalThis);
  const bau = Bau();
  
  
  const { a, button, div, tr, td, table, tbody, h1, span } = bau.tags;

  const random = (max) => Math.round(Math.random() * 1000) % max;

  const A = [
    "pretty",
    "large",
    "big",
    "small",
    "tall",
    "short",
    "long",
    "handsome",
    "plain",
    "quaint",
    "clean",
    "elegant",
    "easy",
    "angry",
    "crazy",
    "helpful",
    "mushy",
    "odd",
    "unsightly",
    "adorable",
    "important",
    "inexpensive",
    "cheap",
    "expensive",
    "fancy",
  ];
  const C = [
    "red",
    "yellow",
    "blue",
    "green",
    "pink",
    "brown",
    "purple",
    "brown",
    "white",
    "black",
    "orange",
  ];
  const N = [
    "table",
    "chair",
    "house",
    "bbq",
    "desk",
    "car",
    "pony",
    "cookie",
    "sandwich",
    "burger",
    "pizza",
    "mouse",
    "keyboard",
  ];

  let nextId = 1;

  const buildLabel = () =>
    bau.state(
      `${A[random(A.length)]} ${C[random(C.length)]} ${N[random(N.length)]}`,
    );

  const buildData = (count) => {
    const data = new Array(count);

    for (let i = 0; i < count; i++) {
      data[i] = {
        id: nextId++,
        label: buildLabel(),
      };
    }

    return data;
  };

  const dataState = bau.state([]);
  let selectedRow = null;

  const run = () => {
    dataState.val = buildData(1000);
    selectedRow = null;
  };

  const runLots = () => {
    dataState.val = buildData(10000);
    selectedRow = null;
  };

  const add = () => {
    dataState.val.push(...buildData(1000));
  };

  const update = () => {
    for (let i = 0; i < dataState.val.length; i += 10) {
      const r = dataState.val[i];
      const label = dataState.val[i].label;
      label.val = r.label.val + " !!!";
    }
  };

  const swapRows = () => {
    if (dataState.val.length > 998) {
      const data = dataState.val;
      const dataTmp = data[1];
      dataState.val[1] = data[998];
      dataState.val[998] = dataTmp;
    }
  };

  const clear = () => {
    dataState.val = [];
    selectedRow = null;
  };

  const remove = (id) => () => {
    const idx = dataState.val.findIndex((d) => d.id === id);
    if (idx > -1) {
      dataState.val.splice(idx, 1);
    }
  };

  const selectRow = (event) => {
    if (selectedRow) {
      selectedRow.className = "";
    }
    selectedRow = event.target.parentNode.parentNode;
    selectedRow.className = "danger";
  };

  const Row = ({ id, label }) => {
    const tdIdEl = td({ class: "col-md-1" }, id);
    const aLabelEl = a({ onclick: selectRow }, label);
    const aRemove = a(
      { onclick: remove(id) },
      span({ class: "glyphicon glyphicon-remove", "aria-hidden": true }),
    );

    return tr(
      {
        bauUpdate: (element, data) => {
          tdIdEl.textContent = data.id;
          aLabelEl.replaceWith(a({ onclick: selectRow }, data.label));
          aRemove.onclick = remove(data.id);
        },
      },
      tdIdEl,
      td({ class: "col-md-4" }, aLabelEl),
      td({ class: "col-md-1" }, aRemove),
      td({ class: "col-md-6" }),
    );
  };

  const Button = ({ id, title, onclick }) =>
    div(
      { class: "col-sm-6 smallpad" },
      button(
        { type: "button", class: "btn btn-primary btn-block", id, onclick },
        title,
      ),
    );

  const Jumbotron = ({}) =>
    div(
      { class: "jumbotron" },
      div(
        { class: "row" },
        div({ class: "col-md-6" }, h1("Bau Non-Keyed Benchmark")),
        div(
          { class: "col-md-6" },
          div(
            { class: "row" },
            Button({ id: "run", title: "Create 1,000 rows", onclick: run }),
            Button({
              id: "runlots",
              title: "Create 10,000 rows",
              onclick: runLots,
            }),
            Button({
              id: "add",
              title: "Append 1,000 rows",
              onclick: add,
            }),
            Button({
              id: "update",
              title: "Update every 10th row",
              onclick: update,
            }),
            Button({
              id: "clear",
              title: "Clear",
              onclick: clear,
            }),
            Button({
              id: "swaprows",
              title: "Swap Row",
              onclick: swapRows,
            }),
          ),
        ),
      ),
    );

  const Main = () =>
    div(
      { class: "container" },
      Jumbotron({}),
      table(
        { class: "table table-hover table-striped test-data" },
        bau.loop(dataState, tbody(), Row),
        span({
          class: "preloadicon glyphicon glyphicon-remove",
          "aria-hidden": true,
        }),
      ),
    );

  const app = document.getElementById("app");
  app.replaceChildren(Main({}));

  function measure(name, fn) {
    const start = performance.now();
    fn();
    const end = performance.now();
    console.log(`[${name}] ${(end - start).toFixed(2)} ms`);
  }

  console.log("\n🚀 Starting Bau Benchmark...\n");

  const f1 = () => measure("Create 1k", run);
  f1();

  measure("Replace 1k", run);
  runLots(); // Setup 10k
  measure("Partial Update (10k)", () => update());
  measure("Select Row", () => {
    const el = document.querySelector("tbody tr:nth-child(2) td:nth-child(2) a");
    if (el) el.dispatchEvent(new Event("click", { bubbles: true }));
  });
  run(); // Reset to 1k
  measure("Swap Rows", () => swapRows());
  measure("Remove Row", () => {
    const el = document.querySelector("tbody tr:nth-child(2) td:nth-child(3) a");
    if (el) el.dispatchEvent(new Event("click", { bubbles: true }));
  });
  measure("Create 10k", () => runLots());
  measure("Append 1k", () => add());
  measure("Clear", () => clear());

  const count = document.querySelectorAll("tr").length;
  console.log(`✅ Final Row Count: ${count} (Should be 0)`);
// }

// run();
