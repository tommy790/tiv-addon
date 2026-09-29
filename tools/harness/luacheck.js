// Syntax-checks every Lua file in the addon with luaparse.
//
//   cd tools/harness && node luacheck.js ../../jeep_jalopy_interceptor
//
// Neutralises GMod's `continue` (a real keyword in GMod Lua, absent from
// luaparse's grammar) and skips the bundled Wiremod E2 extensions, which use
// their own `e2function` syntax.
'use strict';
const luaparse = require('luaparse');
const fs = require('fs'), path = require('path');

const root = process.argv[2] || path.join(__dirname, '../../jeep_jalopy_interceptor');
const files = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (e.name === 'gmod_wire_expression2' || e.name === 'node_modules') continue;
      walk(p);
    } else if (e.name.endsWith('.lua')) files.push(p);
  }
})(root);

let failed = 0;
for (const f of files.sort()) {
  let src = fs.readFileSync(f, 'utf8');
  src = src.replace(/\bcontinue\b/g, '--continue');
  src = src.replace(/then --continue end/g, 'then end');
  try {
    luaparse.parse(src, { luaVersion: '5.1', comments: false, scope: false });
  } catch (e) {
    failed++;
    console.log(`✖ ${path.relative(root, f)}: ${e.message}`);
  }
}
console.log(`>>> ${files.length} files checked, ${failed} failed`);
process.exit(failed ? 1 : 0);
