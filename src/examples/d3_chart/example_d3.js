async function gdp(country) {
    const resp = await fetch('https://raw.githubusercontent.com/datasets/gdp/master/data/gdp.csv');
    const raw_data = await resp.text();
    const csv = zxp.csv.parse(raw_data);
    const country_data = csv.filter((row) => row['Country Code'] == country && row['Year'] > 2000)
        .map((row) => ({year: row['Year'], gdp: row['Value']}))

    zxp.loadHTML(`
    <html>
        <body>
            <div id="chart" style="width: 800px; height: 600px;"></div>
        </body>
    </html>
  `);

    await zxp.importScript('https://d3js.org/d3.v7.min.js');

    const width = 800, height = 600;
    const margin = { top: 40, right: 40, bottom: 60, left: 100 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3.select('#chart')
        .append('svg')
        .attr('width', width)
        .attr('height', height)
        .attr('xmlns', 'http://www.w3.org/2000/svg')
        .append('g')
        // Shift the inner chart to make room for axes labels!
        .attr('transform', `translate(${margin.left},${margin.top})`);

    // 2. Define the X and Y Scales
    // X Scale: Years (Band scale for bars)
    const xScale = d3.scaleBand()
        .domain(country_data.map(d => d.year))
        .range([0, innerWidth])
        .padding(0.1);

    // Y Scale: GDP (Linear scale from 0 to max GDP)
    const yScale = d3.scaleLinear()
        .domain([0, d3.max(country_data, d => d.gdp)])
        .range([innerHeight, 0]);

    // 3. Draw the X and Y Axes
    // X Axis (Bottom)
    svg.append('g')
        .attr('transform', `translate(0,${innerHeight})`)
        .call(d3.axisBottom(xScale).tickValues(
            // Only show every 5th year so the labels don't overlap
            xScale.domain().filter((d, i) => i % 5 === 0)
        ))
        .attr('font-size', '12px');

    // Y Axis (Left)
    svg.append('g')
        .call(d3.axisLeft(yScale).ticks(10, 's')) 
        .attr('font-size', '12px');

    // 4. Draw the Bars
    svg.selectAll('rect')
        .data(country_data)
        .join('rect')
        .attr('x', d => xScale(d.year))
        .attr('y', d => yScale(d.gdp))
        .attr('width', xScale.bandwidth())
        .attr('height', d => innerHeight - yScale(d.gdp))
        .attr('fill', '#3b82f6'); // Tailwind Blue

    // 5. Add a Title
    svg.append('text')
        .attr('x', innerWidth / 2)
        .attr('y', -10)
        .attr('text-anchor', 'middle')
        .attr('font-family', 'sans-serif')
        .attr('font-size', '20px')
        .attr('font-weight', 'bold')
        .text(`GDP of ${country} Over Time`);

    const chartEl = document.querySelector('#chart');

    // return the SVG
    zxp.fs.writeFileSync('src/examples/d3_chart/output_chart.html', chartEl.outerHTML);

    // return the painted SVG
    const imgObj = zxp.paintElement(chartEl, {width: 800}); 
    // Returns ImageData{data, width, height}

    // Encode raw RGBA pixels to a standard ArrayBuffer (WEBP encoded here)
    const imgBytes = zxp.encode(imgObj, 'webp');
    zxp.fs.writeFileSync('src/examples/d3_chart/output_chart.webp', imgBytes);
    
    // return imgBytes; <-- run `... | kitty +kitten icat` to visualize in terminal

}

gdp('FRA');