// Leaflet GeoJSON example — renders a map with a route overlay to london_route.png.
// Leaflet.js is loaded from CDN via zxp.importScript (bytecode-cached after first call).

async function run() {
  // 1. Set up a page with a map container
  zxp.loadHTML(`
    <html><body>
      <div id="map" style="width:800px;height:600px"></div>
    </body></html>
  `);

  // 2. Load Leaflet (~150 KB, bytecode-cached: ~10x faster on repeat runs)
  await zxp.importScript('https://unpkg.com/leaflet@1.9.4/dist/leaflet.js');

  // 3. Initialise map — no controls needed for a static render
  const map = L.map('map', { zoomControl: false, attributionControl: false })
    .setView([51.505, -0.09], 13);

  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png').addTo(map);

  // 4. Draw a route: Hyde Park → City of London
  const route = {
    type: 'LineString',
    coordinates: [[-0.15, 51.505], [-0.12, 51.51], [-0.076, 51.508]],
  };
  L.geoJSON(route, { style: { color: 'red', weight: 6, opacity: 0.8 } }).addTo(map);

  // 5. Extract tile positions + SVG overlay
  const tiles = Array.from(document.querySelectorAll('img.leaflet-tile')).map(img => ({
    url: img.src,
    x: parseInt(img.style.left || 0, 10),
    y: parseInt(img.style.top || 0, 10),
  }));
  const svgEl = document.querySelector('.leaflet-overlay-pane svg');
  const svgString = svgEl ? svgEl.outerHTML : '';
  console.log(`Extracted ${tiles.length} tiles and SVG overlay`);

  // 6. Fetch each tile image buffer in sequence
  const readyTiles = [];
  for (const t of tiles) {
    try {
      const res = await fetch(t.url);
      readyTiles.push({ buffer: await res.arrayBuffer(), x: t.x, y: t.y });
    } catch (e) {
      console.log(`  Failed to fetch ${t.url}`);
    }
  }

  // 7. Composite tiles + SVG route → PNG via Zig compositor
  zxp.generateRoutePng(readyTiles, svgString, 'london_route.png');
  console.log('Generated: london_route.png');
}

run().catch(e => console.error('Error:', e.message, e.stack));
