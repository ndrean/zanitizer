async function delayedError(ms) {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error("🔴 Failed")), ms);
  });
}

start = Date.now();
console.log("🔵 Starting first async operation...IIEE");
const delay = 900;

delayedError(delay).catch((err) => {
  console.log(
    "🔴 Async error received after ",
    Date.now() - start,
    "ms:",
    err.message
  );
});
