const { JSDOM } = require("jsdom");
const { performance } = require("perf_hooks");

const values = [100, 1000, 10_000, 20_000, 50_000];

console.log("\n=== JSDOM Benchmark --------------------------------\n");

// We iterate through the values, creating a FRESH environment each time
for (const nb of values) {
  const globalStart = performance.now();

  // 1. Initialize JSDOM (Cold Boot)
  // We enable runScripts so we can execute the test logic inside the context
  const dom = new JSDOM(`<!DOCTYPE html><body></body>`, {
    runScripts: "dangerously",
    resources: "usable",
  });

  const { window } = dom;

  // 2. Inject the Global Variable 'NB'
  window.NB = nb;

  // 3. Polyfill 'setTextContentAsText'
  // (Your Zig engine seems to have this custom method, JSDOM does not)
  window.HTMLElement.prototype.setTextContentAsText = function (text) {
    this.textContent = text;
  };

  // 4. The Benchmark Script
  // (Exact copy of your logic)
  const scriptContent = `
    let start = performance.now();
    const NB = window.NB; // Access injected global
    console.log(\`[Internal] Starting DOM creation test with \${NB} elements\`);
    
    const btn = document.createElement("button");
    const form = document.createElement("form");
    form.appendChild(btn);
    document.body.appendChild(form);

    const mylist = document.createElement("ul");

    for (let i = 1; i <= NB; i++) {
      const item = document.createElement("li");
      item.textContent = "Item " + i * 10;
      item.setAttribute("id", i.toString());
      mylist.appendChild(item);
    }
    document.body.appendChild(mylist);

    const lis = document.querySelectorAll("li");
    
    // Start Event Phase
    // start = performance.now();
    let clickCount = 0;
    
    // Create the click event object once to simulate your dispatch logic
    // Note: In JSDOM, simple strings in dispatchEvent don't work like raw engine calls sometimes,
    // but we will try to match your syntax: btn.dispatchEvent(new Event("click"));
    
    btn.addEventListener("click", () => {
      clickCount++;
      btn.textContent = \`Clicked \${clickCount}\`;
    });

    const clickEvent = new window.Event("click");
    for (let i = 0; i < NB; i++) {
      btn.dispatchEvent(clickEvent);
    }

    let time = performance.now() - start;

    console.log(
      JSON.stringify({
        time: time.toFixed(2),
        elementCount: lis.length,
        last_li_id: lis[lis.length - 1].getAttribute("id"),
        last_li_text: lis[lis.length - 1].textContent,
        success: clickCount === NB,
      })
    );
  `;

  // 5. Execute
  console.log(`[Node] Running with NB=${nb}`);
  window.eval(scriptContent);

  const globalEnd = performance.now();
  const totalMs = (globalEnd - globalStart).toFixed(2);

  console.log(`⚡️ JSDOM Total Time: ${totalMs}ms\n`);

  // 6. Cleanup (JSDOM doesn't require manual deinit like Zig, but we close window)
  window.close();
}
