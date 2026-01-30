console.log("[Main] 🚀 Spawning Worker...");

const w = new Worker("js/worker/worker_task.js", { type: "module" });

w.onerror = (e) => {
  console.log(`[Main] 💥 WORKER ERROR CAUGHT: "${e.message}"`);
  // We return true to say "we handled it, don't crash the browser/runtime"
  return true;
};

w.onmessage = (e) => {
  console.log(`[Main] 📩 Received Message from Worker: "${e.data}"`);
  return true;
};

console.log("[Main] 👉 Step 1: Happy Path");
w.postMessage({ cmd: "calc", name: "zig", a: 10, b: 20 });

setTimeout(() => {
  console.log("\n[Main] 👉 Step 2: Triggering SYNC error...");
  w.postMessage({ cmd: "throw_sync" });
}, 500);

setTimeout(() => {
  console.log("\n[Main] 👉 Step 3: Triggering ASYNC error...");
  w.postMessage({ cmd: "throw_async" });
}, 1000);

setTimeout(() => {
  console.log("\n[Main] 👉 Step 4: Triggering HANDLED error...");
  w.postMessage({ cmd: "throw_handled" });
}, 2000);

setTimeout(() => {
  console.log("\n[Main] 👉 Step 5: Checking vitality...");
  w.postMessage({ cmd: "calc", a: 99, b: 1 });
}, 3000);

setTimeout(() => {
  console.log("\n[Main] 🏁 Test Complete. Terminating.");
}, 4000);

setTimeout(() => {
  console.log("[Main] 👋 Bye!");
  w.terminate();
}, 5000);
