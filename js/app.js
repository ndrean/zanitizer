// app.js
import { add, PI } from "./math.js";

console.log("Loading module...");
const result = add(PI, 10);
console.log(`Result from ESM: ${result}`);
