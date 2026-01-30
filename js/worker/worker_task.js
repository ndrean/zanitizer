// Imports work inside Workers now

import { capitalize } from "../vendor/es-toolkit.min.js";
try {
  importScripts("js/utils.js");
} catch (e) {
  console.log("[Worker] Error loading script: " + e);
}

console.log("[Worker] 🟢 Alive and ready!");
console.log("[JS] Checking globalThis: ", Object.keys(globalThis).join(","));

// Standard Worker API
onmessage = (e) => {
  const { cmd, name, a, b } = e.data;
  // console.log(`[Worker] 📥 Command: ${cmd}`); // Optional: keep logs clean

  switch (cmd) {
    case "calc":
      // === TEST 0: Happy Path ===
      // Proves the worker is still alive after previous errors
      const sum = MathLib.add(a, b);
      const source = name ? capitalize(name) : "Generic Worker";
      postMessage(`Calculation: ${sum} (via ${capitalize(source)})`);
      break;

    case "throw_sync":
      // TEST 1: Synchronous Throw
      // Expected: Caught by Zig loop -> Bubbles to Main Thread w.onerror
      onerror = null; // Ensure no local shield
      console.log("[Worker] 🧨 Throwing SYNC error now...");
      throw new Error("Synchronous Main-Thread Panic!");

    case "throw_async":
      // TEST 2: Asynchronous Throw
      // Expected: Caught by Zig Event Loop (executePendingJob) -> Bubbles to Main Thread
      onerror = null;
      console.log("[Worker] ⏳ Queuing ASYNC error (50ms)...");
      setTimeout(() => {
        console.log("[Worker] 🧨 Timer firing, about to throw...");
        throw new Error("Asynchronous Event-Loop Panic!");
      }, 50);
      break;

    // case "fetch_test":
    //   console.log("[Worker] 🌍 Fetching data from httpbin...");

    //   try {
    //     // Native fetch (returns a Promise that resolves to the body string/bytes)
    //     const result = await fetch("https://httpbin.org/json");

    //     // Since your current C-binding returns the raw body string:
    //     console.log(`[Worker] 📦 Bytes received: ${result.length}`);

    //     postMessage("Fetch Success: " + result.substring(0, 50) + "...");
    //   } catch (err) {
    //     console.log(`[Worker] ❌ Network Error: ${err}`);
    //     throw err; // Will be caught by your new async error handler!
    //   }
    //   break;

    case "throw_handled":
      // TEST 3: Local Suppression
      // Expected: Caught by local 'onerror' -> Returns true -> Main Thread hears NOTHING

      //Define local trap
      onerror = (err) => {
        // Note: err might be an event object or message string depending on implementation
        const msg = err.message || err;
        console.log(`[Worker] 🛡️ LOCAL DEFENSE: Caught "${msg}"`);
        console.log("[Worker] 🛡️ Suppressing error. Returning true.");
        return true; // <--- The Magic Boolean
      };

      console.log("[Worker] 🛡️ Shields up. Throwing error...");
      throw new Error("I am a controlled explosion.");
      break;
  }
};
