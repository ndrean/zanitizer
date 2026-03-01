async function run() {
    const res = await fetch("file://src/examples/frameworks/solidjs/test_solidjs.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();
}

run();