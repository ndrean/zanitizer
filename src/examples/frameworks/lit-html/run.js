async function run() {    
    const res = await fetch("file://src/examples/frameworks/lit-html/js-bench-lit-html.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();
}

run();