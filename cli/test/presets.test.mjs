import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { appliesTo, describeMatch, loadPresets, matchPresets } from '../lib/presets.mjs';
import { readLock } from '../lib/lock.mjs';
import { main } from '../torii.mjs';

const catalog = loadPresets();

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'torii-presets-'));
}

function writeResource(root, name, manifest) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'fxmanifest.lua'), manifest);
}

function run(args) {
  let out = '';
  let err = '';
  const code = main(args, { out: (s) => (out += s), err: (s) => (err += s) });
  return { code, out, err };
}

const OX_LIB = "fx_version 'cerulean'\nauthor 'Overextended'\nrepository 'https://github.com/overextended/ox_lib'\nserver_script 'server.lua'\n";

test('every preset has the evidence fields and plausible permissions', () => {
  assert.ok(catalog.presets.length >= 5);
  for (const preset of catalog.presets) {
    assert.match(preset.id, /^[\w.-]+$/);
    assert.ok(preset.resources.length > 0, preset.id);
    assert.match(preset.origin, /^https:\/\/github\.com\//, preset.id);
    assert.match(preset.checked.commit, /^[0-9a-f]{7,40}$/, preset.id);
    assert.match(preset.checked.date, /^\d{4}-\d{2}-\d{2}$/, preset.id);
    assert.ok(preset.checked.lookedFor.includes('PerformHttpRequest'), preset.id);
    assert.equal(typeof preset.grants.dynamic_code, 'boolean', preset.id);
    assert.ok(Array.isArray(preset.grants.http), preset.id);
    assert.ok(preset.why.length > 0, preset.id);
    for (const entry of preset.grants.http) {
      assert.ok(!entry.includes('*'), `${preset.id}: no wildcard in ${entry}`);
      assert.ok(entry.includes('/'), `${preset.id}: a shared host needs a path prefix (${entry})`);
    }
  }
});

test('a preset is matched by folder name and checked against the manifest origin', () => {
  const found = matchPresets(
    [
      { name: 'ox_lib', manifestText: OX_LIB },
      { name: 'ox_inventory', manifestText: "fx_version 'cerulean'\nauthor 'Someone Else'\n" },
      {
        name: 'es_extended',
        manifestText: "fx_version 'cerulean'\ndescription 'The Core resource that provides the functionalities for all other resources.'\n",
      },
      { name: 'qb-core', manifestText: "fx_version 'cerulean'\n" },
      { name: 'my_own_script', manifestText: "fx_version 'cerulean'\n" },
      { name: 'oxmysql', manifestText: "fx_version 'cerulean'\n" },
    ],
    catalog,
  );
  assert.deepEqual(found.matches.map((m) => [m.resource, m.originOk]), [
    ['ox_lib', true],
    ['ox_inventory', false],
    ['es_extended', true],
    ['qb-core', false],
  ]);
  assert.deepEqual(found.unsupported.map((u) => u.resource), ['oxmysql']);
});

test('a preset applies only on request, and never when the manifest lacks the expected origin', () => {
  const ok = { originOk: true };
  const bad = { originOk: false };
  const unknown = { originOk: null };
  assert.equal(appliesTo(ok, false), false);
  assert.equal(appliesTo(ok, true), true);
  assert.equal(appliesTo(bad, true), false);
  assert.equal(appliesTo(unknown, true), false, 'no origin hint means never applied');
});

test('the description names the evidence and the user duties', () => {
  const found = matchPresets([{ name: 'ox_lib', manifestText: OX_LIB }], catalog);
  const text = describeMatch(found.matches[0], false).join('\n');
  assert.match(text, /66906c5/);
  assert.match(text, /dynamic_code/);
  assert.match(text, /api\.github\.com\/repos\/overextended/);
  assert.match(text, /you add/);
  assert.match(text, /not applied/);
});

test('approve prints known libraries, writes nothing for them by default, and applies them with --use-presets', () => {
  const root = tempDir();
  try {
    writeResource(root, 'ox_lib', OX_LIB);
    writeResource(root, 'oxmysql', "fx_version 'cerulean'\nserver_script 'dist/build.js'\n");
    const lockPath = path.join(root, 'lock.json');

    const preview = run(['approve', root, '--lock', lockPath]);
    assert.equal(preview.code, 0);
    assert.match(preview.out, /Known libraries found/);
    assert.match(preview.out, /ox_lib/);
    assert.match(preview.out, /not applied \(add --use-presets/);
    assert.match(preview.out, /oxmysql/);
    assert.match(preview.out, /JavaScript runtime/);
    assert.ok(!/\+ ox_lib/.test(preview.out), 'nothing is proposed without the flag');

    const applied = run(['approve', root, '--lock', lockPath, '--use-presets', '--write']);
    assert.equal(applied.code, 0);
    assert.match(applied.out, /\+ ox_lib/);
    const lock = readLock(lockPath);
    assert.equal(lock.resources.ox_lib.dynamic_code, true);
    assert.ok(lock.resources.ox_lib.http.includes('api.github.com/repos/overextended/ox_lib/releases/latest'));
    assert.ok(lock.resources.ox_lib.http.every((entry) => entry.endsWith('/releases/latest')), 'only the read-only version check');
    assert.equal(lock.resources.oxmysql, undefined, 'unsupported runtimes never get a grant');
  } finally {
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});

test('every shipped preset has an origin hint, so none can be applied blindly', () => {
  for (const preset of catalog.presets) {
    assert.equal(typeof preset.originHint, 'string', preset.id);
    assert.ok(preset.originHint.length >= 5, preset.id);
  }
});

test('an impostor named es_extended or ox_lib does not get the preset', () => {
  const root = tempDir();
  try {
    writeResource(root, 'ox_lib', "fx_version 'cerulean'\nauthor 'Totally Legit'\nserver_script 'server.lua'\n");
    const lockPath = path.join(root, 'lock.json');
    const result = run(['approve', root, '--lock', lockPath, '--use-presets', '--write']);
    assert.equal(result.code, 0);
    assert.match(result.out, /NOT applied/);
    const lock = fs.existsSync(lockPath) ? readLock(lockPath) : { resources: {} };
    assert.equal(lock.resources.ox_lib, undefined);
    assert.equal(lock.resources.es_extended, undefined);
  } finally {
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  }
});
