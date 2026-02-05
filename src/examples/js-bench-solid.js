import { createSignal, createSelector, batch } from "solid-js";
import { render } from "solid-js/web";
import html from "solid-js/html";

const adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]; // prettier-ignore
const colors = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]; // prettier-ignore
const nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]; // prettier-ignore

const random = (max) => Math.round(Math.random() * 1000) % max;

let nextId = 1;

const buildData = (count) => {
  let data = new Array(count);
  for (let i = 0; i < count; i++) {
    const [label, setLabel] = createSignal(
      `${adjectives[random(adjectives.length)]} ${colors[random(colors.length)]} ${nouns[random(nouns.length)]}`,
    );
    data[i] = { id: nextId++, label, setLabel };
  }
  return data;
};

const Button = (props) => {
  const { id, title, onClick } = props.actions;

  return html`
    <div class="col-sm-6 smallpad">
      <button
        id=${id}
        class="btn btn-primary btn-block"
        type="button"
        onclick=${onClick}
      >
        ${title}
      </button>
    </div>
  `;
};

try {
  render(() => {
    const [data, setData] = createSignal([]);
    const [selected, setSelected] = createSignal(null);

    const actions = {
      run: {
        id: "run",
        title: "Create 1,000 rows",
        onClick: () => setData(buildData(1_000)),
      },
      runLots: {
        id: "runlots",
        title: "Create 10,000 rows",
        onClick: () => setData(buildData(10_000)),
      },
      add: {
        id: "add",
        title: "Append 1,000 rows",
        onClick: () => setData((d) => [...d, ...buildData(1_000)]),
      },
      update: {
        id: "update",
        title: "Update every 10th row",
        onClick: () => {
          return batch(() => {
            for (let i = 0, d = data(), len = d.length; i < len; i += 10)
              d[i].setLabel((l) => l + " !!!");
          });
        },
      },
      clear: { id: "clear", title: "Clear", onClick: () => setData([]) },
      swapRows: {
        id: "swaprows",
        title: "Swap Rows",
        onClick: () => {
          const list = data().slice();
          if (list.length > 998) {
            let item = list[1];
            list[1] = list[998];
            list[998] = item;
            setData(list);
          }
        },
      },
    };

    const isSelected = createSelector(selected);

    const Row = (row) => {
      const rowId = row.id;
      return html`
        <tr class=${isSelected(rowId) ? "danger" : ""}>
          <td class="col-md-1">${rowId}</td>
          <td class="col-md-4">
            <a class="lbl" onclick=${() => setSelected(rowId)}
              >${row.label()}</a
            >
          </td>
          <td class="col-md-1">
            <a onclick=${() => setData((d) => d.filter((x) => x.id !== rowId))}>
              <span
                class="remove glyphicon glyphicon-remove"
                aria-hidden="true"
              />
            </a>
          </td>
          <td class="col-md-6" />
        </tr>
      `;
    };

    return html`
      <div class="container">
        <div class="jumbotron">
          <div class="row">
            <div class="col-md-6">
              <h1>Solid</h1>
            </div>
            <div class="col-md-6">
              <div class="row">
                <${Button} actions=${actions.run} />
                <${Button} actions=${actions.runLots} />
                <${Button} actions=${actions.add} />
                <${Button} actions=${actions.update} />
                <${Button} actions=${actions.clear} />
                <${Button} actions=${actions.swapRows} />
              </div>
            </div>
          </div>
        </div>
        <table class="table table-hover table-striped test-data">
          <tbody>
            ${() => data().map(Row)}
          </tbody>
        </table>
        <span
          class="preloadicon glyphicon glyphicon-remove"
          aria-hidden="true"
        />
      </div>
    `;
  }, document.getElementById("main"));
} catch (e) {
  console.error(e);
}
