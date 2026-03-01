async function run() {
    const res = await fetch("file://src/examples/frameworks/solidjs/solid-compiled.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();
}

run();