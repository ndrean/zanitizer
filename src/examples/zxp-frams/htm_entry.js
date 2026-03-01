import htm from "htm";

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (k === "style" && typeof v === "object") {
        const css = Object.entries(v)
          .map(([p, val]) => {
            // camelCase to kebab-case
            const kebab = p.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase());
            return `${kebab}:${val}`;
          })
          .join(";");
        el.setAttribute("style", css);
      } else {
        el.setAttribute(k, v);
      }
    }
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    if (typeof child === "string" || typeof child === "number") {
      el.appendChild(document.createTextNode(String(child)));
    } else if (child instanceof Node) {
      el.appendChild(child);
    }
  }
  return el;
}

const html = htm.bind(h);

globalThis.html = html;
globalThis.h = h;
