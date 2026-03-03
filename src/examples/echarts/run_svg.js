async function run() {
    const res = await fetch("file://src/examples/echarts/echarts_svg.html");
    const html = await res.text();
    zxp.loadHTML(html);
    await zxp.runScripts();

    const svgEl = document.querySelector('#chart svg') || document.querySelector('#chart').firstChild;
    zxp.fs.writeFileSync('src/examples/echarts/echarts_svg.svg', svgEl.outerHTML);
    const svgStr = new XMLSerializer().serializeToString(svgEl);
    const img = zxp.paintSVG(svgStr);
    console.log('img:', img.width, 'x', img.height);
    const bytes = zxp.encode(img, 'png');
    zxp.fs.writeFileSync('src/examples/echarts/echarts_svg.png', bytes);
    // zxp.fs.writeFileSync('src/examples/echarts/test.html', svg);
}

run();