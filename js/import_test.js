// curl -L https://cdn.jsdelivr.net/npm/es-toolkit@1.43.0/+esm  -o es-toolkit.min.js

import * as Module from "js/vendor/es-toolkit.min.js";

console.log("\n[JS] 🚀 Testing external library: es-toolkit\n");
console.log(
  "\n[JS] import ESM module: https://cdn.jsdelivr.net/npm/es-toolkit@1.43.0/+esm \n"
);
console.log("-----------------------------------------");
console.log("[JS] List available primitives:");
console.log("[JS] " + Object.keys(Module).join(", "));
console.log("-----------------------------------------");
console.log("\n");

// 1. Test 'max' function
const numbers = [10, 50, 100, 160];
console.log("[JS] Array: ", numbers);
const m = Module.mean(numbers);
console.log(`[JS] ✅ es-toolkit 'mean': ${m}\n`);

// 2. Test 'chunk' function
const list = [1, 2, 3, 4, 5, 6];
const chunks = Module.chunk(list, 2);
console.log("’JS] list to chunk :", list);
console.log(`[JS] ✅ es-toolkit 'chunk': ${JSON.stringify(chunks)}`);
// Should be [[1,2], [3,4], [5,6]]
console.log("-----------------------------------------\n");
