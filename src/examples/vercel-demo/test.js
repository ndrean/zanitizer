async function run() {
    await zxp.goto("http://localhost:4173");
    const btn = document.querySelector('button');
    btn.dispatchEvent(new Event('click', { bubbles: true }));
    btn.dispatchEvent(new Event('click', { bubbles: true }));
    await new Promise(r => setTimeout(r, 0)); // flush React's microtask queue
    return btn.textContent;
}
run();