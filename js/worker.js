// js/worker.js
console.log("[Worker] Started!");

// 1. Test importScripts (Synchronous load)
try {
  importScripts("js/utils.js");
} catch (e) {
  console.log("[Worker] Error loading script: " + e);
}

// 2. Handle messages from Main
onmessage = function (e) {
  const data = e.data;
  console.log(`[Worker] Received task: ${JSON.stringify(data)}`);

  if (data.op === "calc") {
    // Use the library we imported
    const result = MathLib.add(data.a, data.b);
    console.log(`[Worker] Computed result: ${result}`);

    // Send back result
    postMessage({
      result: result,
      from: "Worker Thread",
    });
  } else if (data.op === "kill") {
    console.log("[Worker] Goodbye!");
    close();
  }
};
