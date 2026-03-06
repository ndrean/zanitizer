import { loadZanitize } from 'zanitize';

const zan = await loadZanitize(
  new URL('./node_modules/zanitize/zanitize.wasm', import.meta.url)
);
zan.init(); // default config

console.log(zan.sanitizeFragment('<script>alert(1)</script><p>ok</p>'));