// Mermaid.js — NOT SUPPORTED by zexplorer.
//
// Mermaid calls getBBox() to compute the SVG viewBox. zexplorer has no geometry
// engine at JS runtime, so getBBox() always returns zeros → blank output.
// See src/mcp.zig example 9 for the full explanation.
