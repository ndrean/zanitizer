// src/examples/test_cli_render.js

// 1. Build a quick DOM using standard Web APIs
function paint() {
  document.body.innerHTML = `
  <div style="padding: 40px; background: #1e1e2e; color: #cdd6f4; font-size: 24px; font-family: monospace;">
    <div style="background: #f38ba8; color: #11111b; padding: 10px; margin-bottom: 20px;">
      CLI RENDER TEST
    </div>
    <div style="display: flex; flex-direction: row; gap: 20px;">
      <div style="background: #89b4fa; padding: 20px; color: #11111b;">Flex Item 1</div>
      <div style="background: #a6e3a1; padding: 20px; color: #11111b;">Flex Item 2</div>
    </div>
  </div>
`;

  return zxp.encode(zxp.paintDOM(document.body), "png");
}

paint();
