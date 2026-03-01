async function run() {    
    const res = await fetch("file://src/examples/frameworks/svelte/js-bench-svelte.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();
}

run();