const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

test('MDT NUI is local, focus-safe and wired only to canonical P6 events', () => {
  const manifest = read('fxmanifest.lua');
  const client = read('client/mdt.lua');
  const html = read('web/index.html');
  const app = read('web/app.js');

  assert.match(manifest, /ui_page 'web\/index\.html'/);
  for (const file of ['web/index.html', 'web/style.css', 'web/lucide.min.js', 'web/app.js']) {
    assert.ok(manifest.includes(`'${file}'`), `${file} missing from manifest`);
  }
  assert.match(client, /RegisterCommand\('mz_police_mdt'/);
  assert.match(client, /response\.ok ~= true[\s\S]*SetNuiFocus\(true, true\)/);
  assert.match(client, /SetNuiFocus\(false, false\)/);
  assert.match(client, /mz_police:server:records:listCases/);
  assert.match(client, /mz_police:server:evidence:list/);
  assert.match(client, /mz_police:server:evidence:linkCase/);
  assert.doesNotMatch(client, /TriggerServerEvent\([^\n]*(?:amount|sentence|fine)/i);
  assert.doesNotMatch(html, /https?:\/\//i);
  assert.doesNotMatch(app.replace('https://${resourceName}', ''), /https?:\/\//i);
});

test('MDT exposes every requested screen and labels unavailable contracts', () => {
  const app = read('web/app.js');
  for (const screen of ['Dashboard', 'Cidadãos', 'Ficha', 'Ocorrências', 'Acusações', 'Multas', 'Mandados', 'Evidências', 'Histórico']) {
    assert.ok(app.includes(`'${screen}'`), `${screen} screen missing`);
  }
  assert.match(app, /catálogo jurídico não expõe|catálogo jurídico aprovado/i);
  assert.match(app, /evidências vinculadas ao caso/i);
  assert.match(app, /associationEnabled === true/);
  assert.match(app, /Preview visual isolado/);
});
