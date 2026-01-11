console.log("[Main] 🚀 Spawning Worker...");

const w = new Worker("js/worker_task.js", { type: "module" });

w.onmessage = (e) => {
  console.log(`[Main] 📩 Message from Worker: "${e.data}"`);

  // Clean up
  w.terminate();
};

w.onerror = (e) => {
  console.log(`[Main] 💥 Worker Error: ${e.message}`);
};

// Send data to worker
w.postMessage({ name: "zig", a: 1, b: 2 });
