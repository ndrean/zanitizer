# HTML parser & JavaScript execution at native speed

Building blocks: 

- `lexbor` [License](https://github.com/lexbor/lexbor/blob/master/LICENSE)
- `quickjs` [icense](https://github.com/bellard/quickjs/blob/master/LICENSE)
  
## What Works Now in `main()`

✅ JS Execution

```zig
const ctx = qjs.JS_NewContext(rt);
const result = qjs.JS_Eval(ctx, "2 + 2", 5, "<input>", 0);
// Returns: 4
```

✅ Extract & Execute Scripts from HTML

```zig
// Fetch HTML from URL
const page = try z.get(allocator, url);
// Parse & find all script tags
const doc = try z.createDocFromString(page);
const scripts = try z.querySelectorAll(allocator, doc, "script");

// Execute each script with QuickJS
for (scripts) |script_elt| {
    const js_code = z.textContent_zc(z.elementToNode(script_elt));
    const result = qjs.JS_Eval(ctx, js_code.ptr, js_code.len, "<script>", 0);
    // Script executed!
}
```

✅ Access JavaScript Variables from Zig

```zig
// JavaScript creates a variable
qjs.JS_Eval(ctx, "var result = 'Hello from JS'", ...);

// Zig accesses it
const global = qjs.JS_GetGlobalObject(ctx);
const result_prop = qjs.JS_GetPropertyStr(ctx, global, "result");
const result_str = qjs.JS_ToCString(ctx, result_prop);
// result_str = "Hello from JS"
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

```txt
┌─────────────────────────────────────┐
│     JavaScript (QuickJS)            │
│  document.createElement("div")      │
│  element.appendChild(child)         │
│  document.querySelector(".foo")     │
└─────────┬───────────────────────────┘
          │ Bridge Functions (Zig)
          ↓
┌─────────────────────────────────────┐
│   Zexplorer/Lexbor Primitives       │
│   z.createElement()                 │
│   z.appendChild()                   │
│   z.querySelectorAll()              │
└─────────┬───────────────────────────┘
          │
          ↓
┌─────────────────────────────────────┐
│      Lexbor C Library               │
│   (Actual DOM Tree in Memory)       │
└─────────────────────────────────────┘
```

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

## Use Cases Enabled

### Server-Side React/Vue/Preact

```js
// React SSR example (with polyfills)
import { renderToString } from 'react-dom/server';

const App = () => (
  <div className="container">
    <h1>Hello from Zig + QuickJS!</h1>
  </div>
);

const html = renderToString(<App />);
// Returns HTML string that Zig can use
```

### Template Engines (Handlebars, Mustache, EJS...)

```js
const template = Handlebars.compile(`
  <div class="user">
    <h2>{{name}}</h2>
    <p>{{email}}</p>
  </div>
`);

const html = template({ name: "John", email: "john@example.com" });
```

### HTMX/Alpine.js SSR

```js
// Process HTMX attributes server-side
const container = document.createElement("div");
container.setAttribute("hx-get", "/api/data");
container.setAttribute("hx-swap", "innerHTML");

document.body.appendChild(container);
// Lex bor DOM now contains the HTMX-ready HTML
```

### Dynamic Component Generation

```js
function createCard(title, content) {
  const card = document.createElement("div");
  card.className = "card";

  const h2 = document.createElement("h2");
  h2.textContent = title;

  const p = document.createElement("p");
  p.textContent = content;

  card.appendChild(h2);
  card.appendChild(p);

  return card;
}

// Generate 100 cards
for (let i = 0; i < 100; i++) {
  const card = createCard(`Item ${i}`, `Description ${i}`);
  document.body.appendChild(card);
}

// Extract final HTML from lexbor
const html = getHTMLFromDOM(); // Your innerHTML() function
```

### Web Scraping with JS Execution

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

QuickJS has **no sandboxing by default**. For production:

```zig
// Set memory limits
qjs.JS_SetMemoryLimit(rt, 10 * 1024 * 1024); // 10MB

// Set stack size
qjs.JS_SetMaxStackSize(rt, 256 * 1024); // 256KB

// Add interrupt handler for timeouts
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

// IMPORTANT: You must execute pending jobs!
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

**Tested and working!** (see [main.zig:204-221](src/main.zig#L204-L221))

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

⚠️ PARTIAL - Needs Polyfills/Implementation

- Streams API.
QuickJS **does NOT include** the Web Streams API (`ReadableStream`, `WritableStream`, `TransformStream`) by default.

Potentially polyfill from JavaScript?

```js
// Use a polyfill like 'web-streams-polyfill'
import { ReadableStream } from 'web-streams-polyfill';

const stream = new ReadableStream({
  start(controller) {
    controller.enqueue("chunk 1");
    controller.enqueue("chunk 2");
    controller.close();
  }
});

for await (const chunk of stream) {
  console.log(chunk);
}
```

Or implement in Zig:

```zig
// Create a native ReadableStream backed by Zig I/O
fn js_createReadableStream(...) callconv(.c) qjs.JSValue {
    // Return a JS object that mimics ReadableStream
    // with getReader(), pipeTo(), etc.
}
```

> Stream parser is implemented in lexbor.

- Event Loop / setTimeout / setInterval. QuickJS has a basic event loop, but `setTimeout`/`setInterval` are _NOT built-in_, or  use the extension `quickjs-libc`

=> Zig implementation

```zig
// Pseudo-code
fn js_setTimeout(ctx: *qjs.JSContext, ...) callconv(.c) qjs.JSValue {
    const callback = argv[0];
    const delay_ms = argv[1];

    // Schedule callback for later execution
    timer_queue.add(callback, delay_ms);

    return JS_NewInt32(ctx, timer_id);
}
```

**Alternative:** Use the `quickjs-libc` extensions (if you include them):

```c
// quickjs-libc.c provides:
// - os.setTimeout()
// - os.setInterval()
// - os module for file I/O
```

To enable, add `quickjs-libc.c` to your build and call `js_init_module_os()`.

- fetch() API  ❌. Use Zigimplementation

```zig
fn js_fetch(ctx: *qjs.JSContext, ...) callconv(.c) qjs.JSValue {
    const url = JS_ToCString(ctx, argv[0]);
    const response = z.get(allocator, url) catch return JS_EXCEPTION;

    const promise = JS_NewPromiseCapability(ctx);
    JS_Call(ctx, promise.resolve, response_text, 1, &response_val);
    return promise.promise;
}
```

### DOM APIs

We bridge Lexbor with the DOM API.

---

## ❌ NOT Supported

### WebAssembly

Alternatives:

- Integrate `wasmer` or `wasmtime` separately
- Use Zig's own WASM support for compiling/running WASM

### Browser-Specific APIs

These are not in QuickJS by default:

- `window`, `document`, `navigator` (but you're building this!)
- `localStorage`, `sessionStorage`
- `WebSocket`, `WebRTC`
- Canvas, WebGL
- Service Workers
- IndexedDB

**But:** You can implement any of these by mapping to Zig functions!

## JavaScript or Zig and Interop

```js
// SLOW
let sum = 0;
for (let i = 0; i < 1_000_000; i++) {
    sum += Math.sqrt(i) * Math.sin(i);
}

//FAST in Zig
const sum = Native.processArray(data);
```

Use JavaScript (QuickJS) for:

- Orchestration & Logic
  
   ```js
   // JavaScript decides what to do
   const products = querySelectorAll(".product");
   const prices = products.map(el => extractPrice(el));
   const stats = z.computeStats(prices); // Zig does math
   ```

- Small Loops (<100 iterations)
  
   ```js
   // Fast enough in JavaScript
   const headers = ["Name", "Age", "Email"];
   const html = headers.map(h => `<th>${h}</th>`).join("");
   ```

- String Templates
  
   ```js
   // Simple string ops are fine
   const report = `Total: ${total}, Average: ${avg}`;
   ```

- Object Manipulation
  
   ```javascript
   const config = { ...defaults, ...userSettings };
   ```

Use Zig (Native) for:

- Large Loops (>1000 iterations)

   ```js
   // ❗️
   for (let i = 0; i < data.length; i++) {
       result[i] = Math.sqrt(data[i]) * Math.sin(data[i]);
   }

   //✅ Zig
   const result = z.transformArray(data);
   ```

- Math-Heavy Computations`

- Text Processing (regex, parsing)

Example:

- Fetch: **Zig** (instant startup vs V8's 50ms warmup)
- Parse: **Lexbor** (30k elements/sec, C-level performance)
- Extract: **JavaScript** (simple logic, fast enough)
- Stats: **Zig** (100x faster than JS loops)
- Template: **JavaScript** (simple string ops, fast enough)

- Statistics using TypedArrays (Zero-Copy):

```javascript
// JS
const data = Array.from({ length: 100_000 }, () => Math.random() * 100);

// Convert to TypedArray for zero-copy performance
const buffer = new Float64Array(data);

// Zig processes at native speed (no copying!)
const stats = z.computeStats(buffer);

console.log(`
    Mean: ${stats.mean}
    Median: ${stats.median}
    Std Dev: ${stats.stddev}
    Min: ${stats.min}
    Max: ${stats.max}
`);
```

- HTML generation: Generate 10,000 product cards
  
```js
// ❌ SLOW: Loop in JavaScript
let html = "";
for (let i = 0; i < 10_000; i++) {
    html += `<div class="card">Product ${i}</div>`;
}

// ✅ FAST: Bulk generation in Zig
const html = z.generateCards(10_000);
```

- Data Transformation Pipeline

```javascript
// Real-world: Process API response

// 1. Fetch (Zig)
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
