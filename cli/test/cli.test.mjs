import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { declarationHash, parseDeclaration } from '../lib/declaration.mjs';
import { mergeAdditions, emptyLock, readLock, serializeLock } from '../lib/lock.mjs';
import { proposalFromEvents, targetToEntry } from '../lib/logs.mjs';
import { addInstallLine, inspectManifest, removeInstallLine } from '../lib/manifest.mjs';
import { main } from '../torii.mjs';

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'torii-test-'));
}

function writeResource(root, name, manifest, extra = {}) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'fxmanifest.lua'), manifest);
  for (const [file, text] of Object.entries(extra)) fs.writeFileSync(path.join(dir, file), text);
  return dir;
}

function run(args) {
  let out = '';
  let err = '';
  const code = main(args, { out: (s) => (out += s), err: (s) => (err += s) });
  return { code, out, err };
}

const MANIFEST = "fx_version 'cerulean'\ngame 'gta5'\n\nserver_script 'server.lua'\n";

test('declaration hash matches the Lua implementation (shared vector)', () => {
  // Same vector as spec/policy_spec.lua
  assert.equal(
    declarationHash({ http: ['discord.com/api/webhooks/123', 'api.example.com'], dynamic_code: true, follow_redirects: false }),
    '1529d180165a4ed687b671ddcf294eb70ddf5878b2ddda8e7edbe89e1951720d',
  );
  assert.equal(
    declarationHash({ http: [' api.example.com ', 'discord.com/api/webhooks/123'], dynamic_code: true }),
    declarationHash({ http: ['discord.com/api/webhooks/123', 'api.example.com'], dynamic_code: true }),
  );
});

test('parseDeclaration reads string, table and call forms and ignores comments', () => {
  const decl = parseDeclaration(`
    fx_version 'cerulean'
    -- torii_http 'commented.example.com'
    torii_http 'a.example.com'
    torii_http { 'b.example.com/v1', "c.example.com" }
    torii_http('d.example.com')
    torii_dynamic_code 'yes'
  `);
  assert.deepEqual(decl.http, ['a.example.com', 'b.example.com/v1', 'c.example.com', 'd.example.com']);
  assert.equal(decl.dynamic_code, true);
  assert.equal(decl.follow_redirects, false);
});

test('inspectManifest recognises server code, install state and other runtimes', () => {
  assert.equal(inspectManifest(MANIFEST).hasServerCode, true);
  assert.equal(inspectManifest("fx_version 'cerulean'\nclient_script 'c.lua'\n").hasServerCode, false);
  assert.equal(inspectManifest("shared_script '@ox_lib/init.lua'\n").hasServerCode, false);
  assert.equal(inspectManifest("server_scripts { 'a.lua', 'b.js' }\n").jsOrCsharp, true);
  assert.equal(inspectManifest("fx_version 'x'\nshared_script '@torii/init.lua'\nserver_script 'a.lua'").installed, true);
});

test('install line goes right after fx_version and keeps CRLF', () => {
  assert.equal(addInstallLine(MANIFEST), "fx_version 'cerulean'\nshared_script '@torii/init.lua'\ngame 'gta5'\n\nserver_script 'server.lua'\n");
  assert.ok(addInstallLine(MANIFEST.replace(/\n/g, '\r\n')).includes("fx_version 'cerulean'\r\nshared_script '@torii/init.lua'\r\n"));
  assert.equal(removeInstallLine(addInstallLine(MANIFEST)), MANIFEST);
  assert.equal(removeInstallLine(MANIFEST), MANIFEST);
});

test('install / status / uninstall round trip with backups', () => {
  const root = tempDir();
  try {
    const protectedDir = writeResource(root, 'has_server', MANIFEST);
    writeResource(root, 'client_only', "fx_version 'cerulean'\nclient_script 'c.lua'\n");
    writeResource(path.join(root, '[cat]'), 'nested', MANIFEST);
    writeResource(root, 'mixed', "fx_version 'cerulean'\nserver_scripts { 'a.lua', 'b.js' }\n");
    writeResource(root, 'escrowed', MANIFEST, { 'locked.fxap': 'x' });

    const dry = run(['install', root, '--dry-run']);
    assert.equal(dry.code, 0);
    assert.equal(fs.readFileSync(path.join(protectedDir, 'fxmanifest.lua'), 'utf8'), MANIFEST, 'dry run must not write');

    const first = run(['install', root]);
    assert.equal(first.code, 0);
    assert.match(first.out, /4 changed|4 /);
    assert.match(first.out, /JavaScript\/C# server scripts/);
    assert.match(first.out, /asset-escrow/);
    const text = fs.readFileSync(path.join(protectedDir, 'fxmanifest.lua'), 'utf8');
    assert.ok(text.includes("shared_script '@torii/init.lua'"));
    assert.equal(fs.readFileSync(`${path.join(protectedDir, 'fxmanifest.lua')}.torii.bak`, 'utf8'), MANIFEST);
    assert.ok(fs.readFileSync(path.join(root, '[cat]', 'nested', 'fxmanifest.lua'), 'utf8').includes('@torii/init.lua'));
    assert.ok(!fs.readFileSync(path.join(root, 'client_only', 'fxmanifest.lua'), 'utf8').includes('torii'));

    const second = run(['install', root]);
    assert.match(second.out, /0 changed, 4 already protected/);

    const status = run(['status', root]);
    assert.match(status.out, /protected: 4 /);
    assert.match(status.out, /mixed/);

    const undo = run(['uninstall', root]);
    assert.equal(undo.code, 0);
    assert.equal(fs.readFileSync(path.join(protectedDir, 'fxmanifest.lua'), 'utf8'), MANIFEST);
    assert.ok(!fs.existsSync(`${path.join(protectedDir, 'fxmanifest.lua')}.torii.bak`), 'backup removed once restored');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the torii folder itself is never touched', () => {
  const root = tempDir();
  try {
    writeResource(root, 'torii', "fx_version 'cerulean'\nserver_script 'server/core.lua'\n");
    run(['install', root]);
    assert.ok(!fs.readFileSync(path.join(root, 'torii', 'fxmanifest.lua'), 'utf8').includes('@torii/init.lua'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('targetToEntry converts logged targets and warns about risky hosts', () => {
  assert.deepEqual(targetToEntry('https://api.example.com/v1/users'), { entry: 'api.example.com/v1/users', warnings: [] });
  assert.equal(targetToEntry('https://api.example.com:8443/').entry, 'api.example.com:8443');
  assert.equal(targetToEntry('http://api.example.com/x').entry, 'http://api.example.com/x');
  assert.equal(targetToEntry('<unparseable url>'), null);
  const discord = targetToEntry('https://discord.com/api/webhooks/123/<redacted>');
  assert.equal(discord.entry, 'discord.com/api/webhooks/123');
  assert.equal(discord.warnings.length, 1);
  const bare = targetToEntry('https://discord.com/');
  assert.match(bare.warnings[0], /path prefix/);
  assert.match(targetToEntry('https://pastebin.com/raw/x').warnings.join(), /user content/);
});

test('proposalFromEvents never proposes private targets or bytecode', () => {
  const { additions, notes, warnings } = proposalFromEvents([
    { resource: 'a', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://api.example.com/v1' },
    { resource: 'a', type: 'http', decision: 'would_deny', reason: 'loopback_address', target: 'http://127.0.0.1:30120/' },
    { resource: 'a', type: 'http', decision: 'would_deny', reason: 'invalid_url:userinfo_not_allowed', target: '<unparseable url>' },
    { resource: 'b', type: 'dynamic_code', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'chunk' },
    { resource: 'c', type: 'bytecode', decision: 'deny', reason: 'binary_chunk_refused', target: 'bytecode' },
    { resource: 'torii', type: 'http', decision: 'would_deny', reason: 'x', target: 'https://ignored.example/' },
  ]);
  assert.deepEqual(additions.a.http, ['api.example.com/v1']);
  assert.equal(additions.b.dynamic_code, true);
  assert.equal(additions.c, undefined);
  assert.equal(additions.torii, undefined);
  assert.equal(notes.length, 3);
  assert.ok(warnings.b.length > 0);
});

test('mergeAdditions only ever adds, and the lockfile serialisation is deterministic', () => {
  const lock = mergeAdditions(emptyLock(), { z: { http: ['b.example.com', 'a.example.com'] }, a: { dynamic_code: true } });
  const again = mergeAdditions(lock, { z: { http: ['a.example.com'] } });
  assert.deepEqual(again.resources.z.http, ['b.example.com', 'a.example.com']);
  const text = serializeLock(lock);
  assert.ok(text.indexOf('"a"') < text.indexOf('"z"'));
  assert.ok(text.indexOf('"a.example.com"') < text.indexOf('"b.example.com"'));
  assert.equal(serializeLock(again), serializeLock(mergeAdditions(lock, {})) === text ? serializeLock(again) : text);
});

test('approve --from-logs prints a diff and only writes with --write', () => {
  const root = tempDir();
  try {
    writeResource(
      root,
      'weather',
      "fx_version 'cerulean'\nshared_script '@torii/init.lua'\nserver_script 'server.lua'\ntorii_http 'api.weather.example/v2'\n",
    );
    const log = path.join(root, 'torii.jsonl');
    fs.writeFileSync(
      log,
      [
        { resource: 'weather', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://api.weather.example/v2/now' },
        { resource: 'weather', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://pastebin.com/' },
        { resource: 'weather', type: 'dynamic_code', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'chunk' },
      ]
        .map((event) => JSON.stringify(event))
        .join('\n') + '\n{broken line',
    );
    const lockPath = path.join(root, 'policy.lock.json');

    const preview = run(['approve', root, '--from-logs', log, '--lock', lockPath]);
    assert.equal(preview.code, 0);
    assert.match(preview.out, /\+ weather/);
    assert.match(preview.out, /\+ http\s+api\.weather\.example\/v2/);
    assert.match(preview.out, /\+ http\s+api\.weather\.example\/v2\/now/);
    assert.match(preview.out, /\+ dynamic_code/);
    assert.match(preview.out, /user content/);
    assert.match(preview.out, /Nothing was written/);
    assert.ok(!fs.existsSync(lockPath));

    const written = run(['approve', root, '--from-logs', log, '--lock', lockPath, '--write']);
    assert.equal(written.code, 0);
    const lock = readLock(lockPath);
    assert.ok(lock.resources.weather.http.includes('api.weather.example/v2'));
    assert.equal(lock.resources.weather.dynamic_code, true);
    assert.equal(lock.resources.weather.declaration_hash, declarationHash({ http: ['api.weather.example/v2'] }));

    const again = run(['approve', root, '--from-logs', log, '--lock', lockPath]);
    assert.match(again.out, /No changes|Not proposed|!/);
    assert.ok(!/\+ weather/.test(again.out));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('error handling: missing arguments, unknown commands, missing log', () => {
  assert.equal(run([]).code, 1);
  assert.equal(run(['nope', '.']).code, 1);
  assert.equal(run(['install']).code, 1);
  assert.equal(run(['status', path.join(os.tmpdir(), 'does-not-exist-torii')]).code, 1);
  const root = tempDir();
  try {
    assert.equal(run(['approve', root, '--from-logs', path.join(root, 'missing.jsonl')]).code, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('terminal escape sequences in logs, names and targets never reach the terminal', () => {
  const root = tempDir();
  try {
    const esc = '\u001b[2J\u001b[31m';
    const log = path.join(root, 'torii.jsonl');
    fs.writeFileSync(
      log,
      [
        { resource: `evil${esc}`, type: 'http', decision: 'would_deny', reason: 'x', target: 'https://a.example/' },
        { resource: 'ok', type: 'http', decision: 'would_deny', reason: `loopback_address${esc}`, target: `http://127.0.0.1/${esc}` },
        { resource: 'ok', type: 'http', decision: 'would_deny', reason: 'x', target: `https://host${esc}.example/` },
        { resource: 'ok', type: 'http', decision: 'would_deny', reason: 'x', target: `https://good.example/p${esc}` },
      ]
        .map((event) => JSON.stringify(event))
        .join('\n'),
    );
    const result = run(['approve', root, '--from-logs', log, '--lock', path.join(root, 'lock.json')]);
    assert.ok(!result.out.includes('\u001b'), 'no raw escape in output');
    assert.ok(!result.out.includes('evil'), 'resource names with control characters are dropped');
    assert.ok(!/host\?/.test(result.out), 'targets outside the strict host grammar are dropped');
    assert.equal(targetToEntry(`https://a.example/${esc}`), null);
    assert.equal(targetToEntry('https://[::1]:8080/x').entry, '[::1]:8080/x');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test(
  'install refuses to write through a symlinked backup path',
  { skip: process.platform === 'win32' && 'creating symlinks needs privileges on Windows' },
  () => {
    const root = tempDir();
    try {
      const victim = path.join(root, 'victim.txt');
      fs.writeFileSync(victim, 'untouched');
      const dir = writeResource(root, 'res', MANIFEST);
      fs.symlinkSync(victim, path.join(dir, 'fxmanifest.lua.torii.bak'));
      const result = run(['install', root]);
      assert.equal(result.code, 1);
      assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched');
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  },
);

test('manifest declarations get the same risk warnings as logged targets', () => {
  const root = tempDir();
  try {
    writeResource(root, 'risky', "fx_version 'cerulean'\nserver_script 'a.lua'\ntorii_http 'pastebin.com/raw'\ntorii_http 'discord.com'\ntorii_http 'discord.com/api/webhooks/1'\n");
    const out = run(['approve', root, '--lock', path.join(root, 'lock.json')]).out;
    assert.match(out, /pastebin\.com serves or receives user content/);
    assert.match(out, /discord\.com accepts data from anyone/);
    assert.equal(out.match(/discord\.com accepts data/g).length, 1, 'the scoped webhook entry does not warn');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('hostile resource names cannot pollute prototypes and untrusted text cannot fake output lines', () => {
  const root = tempDir();
  try {
    const log = path.join(root, 'torii.jsonl');
    const lines = ['__proto__', 'constructor', 'toString', 'fine'].map((resource) => ({
      resource,
      type: 'http',
      decision: 'would_deny',
      reason: 'resource_not_in_lockfile',
      target: 'https://api.example.com/v1',
    }));
    lines.push({
      resource: 'fine',
      type: 'http',
      decision: 'would_deny',
      reason: 'loopback_address\n+ fake_resource\n    + http  evil.example',
      target: 'http://127.0.0.1/\u202e',
    });
    fs.writeFileSync(log, lines.map((event) => JSON.stringify(event)).join('\n'));
    const lockPath = path.join(root, 'lock.json');
    const result = run(['approve', root, '--from-logs', log, '--lock', lockPath, '--write']);
    assert.equal(result.code, 0);
    assert.ok(!/^\+ fake_resource/m.test(result.out), 'a log line cannot forge a diff line');
    assert.ok(!result.out.includes('\u202e'));
    assert.equal(({}).http, undefined);
    assert.equal(Object.prototype.hasOwnProperty.call(Object.prototype, 'http'), false);
    assert.deepEqual(Object.keys(readLock(lockPath).resources), ['fine']);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
