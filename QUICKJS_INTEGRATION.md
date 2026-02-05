# HTML parser & JavaScript execution at native speed

Building blocks:

- `lexbor` [License](https://github.com/lexbor/lexbor/blob/master/LICENSE)
- `quickjs` [icense](https://github.com/bellard/quickjs/blob/master/LICENSE)
  
## Zig / QuickJS interop

- JS -> Zig via `globalThis`

```zig
// JavaScript creates a variable
qjs.JS_Eval(ctx, "var result = 'Hello from JS'", ...);

// Zig accesses it
const global = qjs.JS_GetGlobalObject(ctx);
const result_prop = qjs.JS_GetPropertyStr(ctx, global, "result");
const result_str = qjs.JS_ToCString(ctx, result_prop);
// result_str = "Hello from JS"
```

- Inject native Zig functions in the JS runtime for  Data Transformation Pipelines

```javascript
const response = await z.get("/api/products");
const json = await response.json(); // QuickJS built-in

// 2. Extract prices (JavaScript - simple logic)
const prices = json.products.map(p => p.price);

// 3. Convert to TypedArray
const priceBuffer = new Float64Array(prices);

// 4. Complex transformations (Zig)
const stats = z.computeStats(priceBuffer); 
const normalized = z.normalizeArray(priceBuffer);

// 5. Generate HTML (JavaScript - templating)
const html = `
    <div class="stats">
        <h2>Price Analysis</h2>
        <p>Average: $${stats.mean.toFixed(2)}</p>
        <p>Range: $${stats.min} - $${stats.max}</p>
    </div>
    <div class="products">
        ${json.products.map((p, i) =>
            `<div>$${p.price} (${normalized[i].toFixed(2)})</div>`
        ).join("")}
    </div>
`;
```

## Quick start Configuration

Check _build.zig_

```zig
const qjs = @cImport({
    @cInclude("quickjs.h");
});

pub fn main() !void {
    const rt = qjs.JS_NewRuntime();
    defer qjs.JS_FreeRuntime(rt);

    const ctx = qjs.JS_NewContext(rt);
    defer qjs.JS_FreeContext(ctx);

    // Now execute JavaScript!
}
```

## SSR Architecture with API Mapping

Binding Zig wrappers of `lexbor` primitives into `QuickJS`: methods, prop setter/getter,  either on Node, Document, Element, Window.

The DOM is hold by lexbor in memory. QuickJS has access to pointers.

### The API Mapping Dictionary (TODO)

| JavaScript API                          | Zexplorer/Lexbor Function                             |
| --------------------------------------- | ----------------------------------------------------- |
| `document.createElement(tag)`           | `z.createElement(doc, tag)`                           |
| `document.createTextNode(text)`         | `z.createTextNode(doc, text)`                         |
| `element.appendChild(child)`            | `z.appendChild(parent, child)`                        |
| `element.setAttribute(name, value)`     | `z.setAttribute(element, name, value)`                |
| `element.getAttribute(name)`            | `z.getAttribute(element, name)`                       |
| `element.textContent`                   | `z.textContent(element)`                              |
| `element.innerHTML`                     | `z.innerHTML(allocator, element)`                     |
| `element.outerHTML`                     | `z.outerHTML(allocator, element)`                     |
| `document.querySelector(sel)`           | `z.querySelector(allocator, doc, sel)`                |
| `document.querySelectorAll(sel)`        | `z.querySelectorAll(allocator, doc, sel)`             |
| `element.classList.add(name)`           | `z.ClassList.add(name)`                               |
| `element.insertAdjacentHTML(pos, html)` | `z.insertAdjacentHTML(allocator, element, pos, html)` |

### Plan

1. Core DOM APIs
   - createElement, createTextNode
   - appendChild, insertBefore, removeChild
   - setAttribute, getAttribute
   - textContent, innerHTML

2. Query APIs
   - querySelector, querySelectorAll
   - getElementById, getElementsByClassName
   - getElementsByTagName

3. Advanced Features
   - classList manipulation
   - dataset attributes
   - Event listeners (stored in JS, not DOM)
   - Custom element support

4. Framework Support
   - Polyfills for Node.js APIs
   - Module system (import/export)
   - Promise/async support
   - fetch() API for SSR
  
Minimal Working Example concept:

```zig
// types need adjustment
pub fn js_createElement(ctx: *JSContext, _: JSValue, argc: c_int, argv: [*c]JSValue) callconv(.c) JSValue {
    const tag = JS_ToCString(ctx, argv[0]);
    defer JS_FreeCString(ctx, tag);

    // Get document from context
    const doc = getDocumentFromContext(ctx);

    // Create using lexbor
    const element = z.createElement(doc, std.mem.span(tag)) catch return JS_EXCEPTION;

    // Wrap in JS object with methods
    return wrapElement(ctx, element);
}

pub fn js_appendChild(ctx: *JSContext, this: JSValue, argc: c_int, argv: [*c]JSValue) callconv(.c) JSValue {
    const parent = unwrapElement(this);
    const child = unwrapElement(argv[0]);

    // Use lexbor
    z.appendChild(z.elementToNode(parent), z.elementToNode(child));

    return argv[0]; // Return the child
}
```

## Framework Support

Generate _Bytecode_ from Zig code for Preact, SolidJS, VueJS

Template Engines (htmm, solid/html, Handlebars, Mustache, EJS...)

## Example: Web Scraping with JS Execution

```zig
// Fetch page → Parse → Execute its JavaScript → Extract dynamic content
const page = try z.get(allocator, "https://example.com");
const doc = try z.createDocFromString(page);

// Execute page's JavaScript to see what it generates
const scripts = try z.querySelectorAll(allocator, doc, "script");
for (scripts) |script| {
    executeScript(ctx, script);
}

// Now extract data that was generated by JS
const results = try z.querySelectorAll(allocator, doc, ".dynamic-content");
```

### Server-Side Template Rendering

```javascript
// Template engine running in QuickJS
const template = Handlebars.compile("<h1>{{title}}</h1>");
const html = template({title: "Generated by Zig!"});
// Returns HTML that Zig can use
```

### HTMX Backend Processing

```zig
// Process HTMX responses with JS logic
const response = try generateHTMXResponse(allocator, ctx, request);
// JavaScript can manipulate the DOM before sending to client
```

### API Response Transformation

```javascript
// Transform JSON to HTML using JS
const data = JSON.parse(apiResponse);
const html = renderToHTML(data); // JS function
// Zig gets the final HTML
```

## Security Notes

Directory **sandboxing**

Runtime limits:

```zig
// memory limits
qjs.JS_SetMemoryLimit(rt, 10 * 1024 * 1024); // 10MB

// stack size
qjs.JS_SetMaxStackSize(rt, 256 * 1024); // 256KB

// interrupt handler for timeouts
qjs.JS_SetInterruptHandler(rt, handler, userdata);
```

## QuickJS capabilities

✅ ES6 Proxy

```javascript
const handler = {
  get: (target, prop) => {
    console.log(`Accessing: ${prop}`);
    return target[prop];
  },
  set: (target, prop, value) => {
    target[prop] = value;
    return true;
  }
};

const proxy = new Proxy({ count: 0 }, handler);
proxy.count++;  // Logs: "Accessing: count"
```

Use cases:

- Reactive programming (Vue.js-style reactivity)
- Data validation** (intercept setters)
- Object observation (track property access)
- Virtual properties (computed values)

✅Promises

```js
const promise = new Promise((resolve, reject) => {
  resolve("Success!");
});

promise.then(value => {
  console.log(value);
});

```

**From Zig:**

```zig
// Execute promise callbacks
_ = qjs.JS_ExecutePendingJob(qjs.JS_GetRuntime(ctx), null);

// Or execute all pending jobs
var ctx_ptr: ?*qjs.JSContext = undefined;
while (qjs.JS_ExecutePendingJob(qjs.JS_GetRuntime(ctx), &ctx_ptr) > 0) {}
```

✅Async/Await

```js
async function fetchData() {
  return "Data loaded";
}

const result = await fetchData();
```

> Note: Requires manual job queue execution from Zig (see above).

 ✅ Generators

```js
function* fibonacci() {
  let [a, b] = [0, 1];
  while (true) {
    yield a;
    [a, b] = [b, a + b];
  }
}

const fib = fibonacci();
console.log(fib.next().value); // 0
console.log(fib.next().value); // 1
console.log(fib.next().value); // 1
```

✅ Async Generators

```js
async function* asyncGenerator() {
  yield 1;
  yield 2;
  yield 3;
}

for await (const value of asyncGenerator()) {
  console.log(value);
}
```

✅  ES6+ Features

- `class` syntax with inheritance
- Arrow functions
- Template literals
- Destructuring
- Spread operator (`...`)
- `let`, `const` (block scope)
- Modules (`import`/`export`) - with manual setup
- `Symbol`
- `Map`, `Set`, `WeakMap`, `WeakSet`
- `BigInt` (if compiled with `-DCONFIG_BIGNUM`)
- `Reflect` API
- `Object.defineProperty`
- Computed property names

✅ Regular Expressions

```js
const regex = /(\d{3})-(\d{3})-(\d{4})/;
const match = "555-123-4567".match(regex);
```

Includes full ES2020 regex features.

✅ JSON

```js
const obj = { name: "Zig", version: "0.15.2" };
const json = JSON.stringify(obj);
const parsed = JSON.parse(json);
```

✅ Typed Arrays

```js
const buffer = new ArrayBuffer(16);
const view = new Uint8Array(buffer);
view[0] = 42;
```

Includes: `Int8Array`, `Uint8Array`, `Int16Array`, `Uint16Array`, `Int32Array`, `Uint32Array`, `Float32Array`, `Float64Array`, `DataView`.

✅ Complete Timer API

```javascript
// setTimeout - run once after delay
setTimeout(() => {
  console.log("This runs after 1 second");
}, 1000);

// setInterval - run repeatedly
const intervalId = setInterval(() => {
  console.log("This runs every 500ms");
}, 500);

// clearTimeout / clearInterval - cancel timers
clearInterval(intervalId);
```

✅ Integration with Promises & Async/Await

```javascript
// Create promise-based delay function
function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Use with async/await
async function example() {
  console.log("Starting...");
  await delay(1000);
  console.log("1 second later");
}

example();
```

---

⚠️ Streams - Needs Polyfills/Implementation Or implement in Zig:

```zig
// Create a native ReadableStream backed by Zig I/O
fn js_createReadableStream(...) callconv(.c) qjs.JSValue {
    // Return a JS object that mimics ReadableStream
    // with getReader(), pipeTo(), etc.
}
```

> Stream parser is implemented in lexbor.

- Event Loop / setTimeout / setInterval: use the extension `quickjs-libc`?

```c
// quickjs-libc.c provides:
// - os.setTimeout()
// - os.setInterval()
// - os module for file I/O
```

To enable, add `quickjs-libc.c` to your build and call `js_init_module_os()`.
