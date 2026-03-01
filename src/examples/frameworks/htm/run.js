async function run() {    
    const res = await fetch("file://src/examples/frameworks/htm/test_htm.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();
    zxp.save(zxp.paintDOM(document.body), "src/examples/frameworks/htm/paint.png")

}

run();