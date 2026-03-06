import { loadZanitize } from '../../wasm-out/zanitize.js';

const zan = await loadZanitize(new URL('../../wasm-out/zanitize.wasm', import.meta.url));

let pass = 0, fail = 0;
function check(label, html, expectedIn, absentsIn = []) {
  const out = zan.sanitize(html);
  const absents = Array.isArray(absentsIn) ? absentsIn : [absentsIn];
  const expects = Array.isArray(expectedIn) ? expectedIn : [expectedIn];
  let ok = expects.every(e => out.includes(e)) && absents.every(a => !out.includes(a));
  console.log((ok ? '  PASS' : '  FAIL'), label);
  if (!ok) { console.log('        got:', out); console.log('        expected:', expects, 'absent:', absents); }
  ok ? pass++ : fail++;
}

// Default config (safe defaults)
check('XSS: script stripped',        '<script>alert(1)</script><p>ok</p>',        '<p>ok</p>',  '<script>');
check('onclick stripped',            '<a onclick="x()" href="https://a.com">L</a>', 'href=',     'onclick');
check('style attr sanitized',        '<p style="expression(alert(1))">t</p>',       '<p',        'expression');
check('safe content preserved',      '<b>hello</b>',                                '<b>hello</b>');

// JSON config via init()
zan.init('{"removeElements":["b"]}');
check('removeElements b',            '<p>hi <b>bad</b></p>',                        '<p>',       '<b>');

zan.init('{"replaceWithChildrenElements":["b"]}');
check('replaceWithChildren b',       '<p>hi <b>world</b></p>',                      'world',     '<b>');

zan.init('{"elements":[{"name":"p","attributes":["class"]}]}');
check('elements allowlist: p kept',  '<p class="x" onclick="e()">Hi <b>z</b></p>', ['<p ', 'class=', 'Hi', 'z'], ['onclick', '<b>']);

zan.init(); // back to defaults

console.log(`\nResults: ${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
