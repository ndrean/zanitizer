// Chart.js bar chart example — static render to PNG via canvas.toBlob().
//
// LIMITATIONS (be explicit when adapting this for other charts):
//   - animation: false is REQUIRED — Chart.js uses requestAnimationFrame by default;
//     without this the canvas is blank (the animation callback never fires).
//   - responsive: false is REQUIRED — no browser viewport means no resize events.
//   - No tooltips, hover effects, or click interactions (headless, no mouse events).
//   - Canvas output: use canvas.toBlob() → arrayBuffer(), NOT zxp.paintElement().
//     paintElement() works on DOM elements; the canvas is already pixel-rendered by Chart.js.

async function run() {
  // rAF polyfill: Chart.js uses requestAnimationFrame for its render loop.
  // With animation:false the chart renders synchronously, but Chart.js still
  // references rAF at module level — provide a no-op so it doesn't throw.
  window.requestAnimationFrame = cb => setTimeout(cb, 0);

  // Intl is polyfilled globally in polyfills.js (QuickJS has no built-in Intl).

  // Load Chart.js from CDN — bytecode-cached after first call
  await zxp.importScript('https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js');

  // Create a canvas and attach it to the document
  zxp.loadHTML('<html><body></body></html>');
  const canvas = document.createElement('canvas');
  canvas.width = 800;
  canvas.height = 600;
  document.body.appendChild(canvas);

  new Chart(canvas, {
    type: 'bar',
    data: {
      labels: ['Zig', 'Rust', 'C++', 'Go', 'Python'],
      datasets: [{
        label: 'Performance (imaginary units)',
        data: [150, 145, 140, 120, 80],
        backgroundColor: [
          'rgba(255,99,132,0.8)', 'rgba(54,162,235,0.8)',
          'rgba(255,206,86,0.8)', 'rgba(75,192,192,0.8)', 'rgba(153,102,255,0.8)',
        ],
        borderColor: '#000',
        borderWidth: 2,
      }],
    },
    options: {
      animation: false,    // REQUIRED for headless — renders synchronously
      responsive: false,   // REQUIRED — no browser viewport available
      plugins: {
        title: { display: true, text: 'Language Speed Comparison', font: { size: 24 } },
      },
    },
  });

  // Chart.js has drawn synchronously (animation:false). Read pixels via toBlob.
  const blob = await canvas.toBlob();
  const bytes = await blob.arrayBuffer();
  zxp.fs.writeFileSync('src/examples/chartjs/chart_JS_test.png', bytes);
  return bytes; // returning an ArrayBuffer → MCP sends it as a base64 image
}

run().catch(e => console.error('Error:', e.message, e.stack));
