// app.js
import { add, PI } from "./math.js";
import { createSignal, createEffect } from "vendor/solid.js";

console.log("[JS] ❇️ Loading 'math.js' module...");
const result = add(PI, 10);
console.log(`[JS] Result from ESM: ${result}`);

console.log("\n[JS] 🚀 Using SolidJS....\n");
const [count, setCount] = createSignal(1);

createEffect(() => {
  console.log("[JS] Count change:", count());
});

const max_iter = 3;
console.log(`[JS] Let's iterate ${max_iter} times and observe reactivity`);

let iterations = 0;

const id = setInterval(() => {
  iterations++;
  setCount((prev) => prev * 2);

  if (iterations >= max_iter) {
    clearInterval(id);
    console.log(
      `[JS] Stopped after ${max_iter} iterations. Final value is: ${count()}`
    );
  }
}, 1000);
