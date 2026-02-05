import { template as _$template } from "solid-js/web";
import { delegateEvents as _$delegateEvents } from "solid-js/web";
import { className as _$className } from "solid-js/web";
import { effect as _$effect } from "solid-js/web";
import { createComponent as _$createComponent } from "solid-js/web";
import { insert as _$insert } from "solid-js/web";
import { addEventListener as _$addEventListener } from "solid-js/web";
import { setAttribute as _$setAttribute } from "solid-js/web";
var _tmpl$ = /*#__PURE__*/_$template(`<div class="col-sm-6 smallpad"><button class="btn btn-primary btn-block"type=button>`),
  _tmpl$2 = /*#__PURE__*/_$template(`<div class=container><div class=jumbotron><div class=row><div class=col-md-6><h1>Solid</h1></div><div class=col-md-6><div class=row></div></div></div></div><table class="table table-hover table-striped test-data"><tbody></tbody></table><span class="preloadicon glyphicon glyphicon-remove"aria-hidden=true>`),
  _tmpl$3 = /*#__PURE__*/_$template(`<tr><td class=col-md-1></td><td class=col-md-4><a class=lbl> </a></td><td class=col-md-1><a><span class="remove glyphicon glyphicon-remove"aria-hidden=true></span></a></td><td class=col-md-6>`);
import { createSignal, createSelector, batch, For } from "solid-js";
import { render } from "solid-js/web";
const adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]; // prettier-ignore
const colors = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]; // prettier-ignore
const nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]; // prettier-ignore

const random = max => Math.round(Math.random() * 1000) % max;
let nextId = 1;
const buildData = count => {
  let data = new Array(count);
  for (let i = 0; i < count; i++) {
    const [label, setLabel] = createSignal(`${adjectives[random(adjectives.length)]} ${colors[random(colors.length)]} ${nouns[random(nouns.length)]}`);
    data[i] = {
      id: nextId++,
      label,
      setLabel
    };
  }
  return data;
};
const Button = ([id, text, fn]) => (() => {
  var _el$ = _tmpl$(),
    _el$2 = _el$.firstChild;
  _$addEventListener(_el$2, "click", fn, true);
  _$setAttribute(_el$2, "id", id);
  _$insert(_el$2, text);
  return _el$;
})();
render(() => {
  const [data, setData] = createSignal([]);
  const [selected, setSelected] = createSignal(null);
  const run = () => setData(buildData(1_000));
  const runLots = () => setData(buildData(10_000));
  const add = () => setData(d => [...d, ...buildData(1_000)]);
  const update = () => batch(() => {
    for (let i = 0, d = data(), len = d.length; i < len; i += 10) d[i].setLabel(l => l + " !!!");
  });
  const clear = () => setData([]);
  const swapRows = () => {
    const list = data().slice();
    if (list.length > 998) {
      let item = list[1];
      list[1] = list[998];
      list[998] = item;
      setData(list);
    }
  };
  const isSelected = createSelector(selected);
  return (() => {
    var _el$3 = _tmpl$2(),
      _el$4 = _el$3.firstChild,
      _el$5 = _el$4.firstChild,
      _el$6 = _el$5.firstChild,
      _el$7 = _el$6.nextSibling,
      _el$8 = _el$7.firstChild,
      _el$9 = _el$4.nextSibling,
      _el$0 = _el$9.firstChild;
    _$insert(_el$8, _$createComponent(Button, ["run", "Create 1,000 rows", run]), null);
    _$insert(_el$8, _$createComponent(Button, ["runlots", "Create 10,000 rows", runLots]), null);
    _$insert(_el$8, _$createComponent(Button, ["add", "Append 1,000 rows", add]), null);
    _$insert(_el$8, _$createComponent(Button, ["update", "Update every 10th row", update]), null);
    _$insert(_el$8, _$createComponent(Button, ["clear", "Clear", clear]), null);
    _$insert(_el$8, _$createComponent(Button, ["swaprows", "Swap Rows", swapRows]), null);
    _$insert(_el$0, _$createComponent(For, {
      get each() {
        return data();
      },
      children: row => {
        let rowId = row.id;
        return (() => {
          var _el$1 = _tmpl$3(),
            _el$10 = _el$1.firstChild,
            _el$11 = _el$10.nextSibling,
            _el$12 = _el$11.firstChild,
            _el$13 = _el$12.firstChild,
            _el$14 = _el$11.nextSibling,
            _el$15 = _el$14.firstChild;
          _el$10.textContent = rowId;
          _el$12.$$click = () => setSelected(rowId);
          _el$15.$$click = () => setData(d => d.filter(x => x.id !== rowId));
          _$effect(_p$ => {
            var _v$ = isSelected(rowId) ? "danger" : "",
              _v$2 = row.label();
            _v$ !== _p$.e && _$className(_el$1, _p$.e = _v$);
            _v$2 !== _p$.t && (_el$13.data = _p$.t = _v$2);
            return _p$;
          }, {
            e: undefined,
            t: undefined
          });
          return _el$1;
        })(); // prettier-ignore
      }
    }));
    return _el$3;
  })();
}, document.getElementById("main"));
_$delegateEvents(["click"]);