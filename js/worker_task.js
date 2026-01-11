// Imports work inside Workers now
// ⚠️ User `globalThis` to get `onmessage` and `postMessage`!

import { capitalize } from "vendor/es-toolkit.min.js";
try {
  importScripts("js/utils.js");
} catch (e) {
  console.log("[Worker] Error loading script: " + e);
}

console.log("[Worker] 🟢 Alive and ready!");
console.log("[JS] globalThis: ", Object.keys(globalThis).join(","));

// Standard Worker API
onmessage = (e) => {
  const { name, a, b } = e.data;
  console.log(`[Worker] 📫 Received object: ${JSON.stringify(e.data)}`);

  const niceName = capitalize(name);
  const reply = `Hello, ${niceName}! The total is : ${MathLib.add(a, b)}`;

  // Send back
  postMessage(reply);
};
