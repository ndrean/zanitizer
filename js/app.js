// app.js
import { add, PI } from "./math.js";

console.log("[JS] Loading module...");
const result = add(PI, 10);
console.log(`[JS] Result from ESM: ${result}`);
