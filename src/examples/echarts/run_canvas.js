// ECharts canvas renderer — NOT RECOMMENDED. Use SVG instead (run_svg.js).
//
// Canvas works but stroke() fills open paths as closed polygons → triangle
// artifacts on axis ticks, blurred text anti-aliasing. SVG renderer via
// zxp.paintSVG() is pixel-perfect with no such issues.
