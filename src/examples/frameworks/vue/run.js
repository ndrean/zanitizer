async function run() {    
    const res = await fetch("file://src/examples/frameworks/vue/js-bench-vue.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();
}

run();