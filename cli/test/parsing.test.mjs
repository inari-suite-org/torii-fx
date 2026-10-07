import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { normalizeEntry } from '../lib/entries.mjs';
import { lex } from '../lib/lua-lite.mjs';
import { inspectManifest } from '../lib/manifest.mjs';
import { main } from '../torii.mjs';

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'torii-parse-'));
}

function writeResource(root, name, manifest) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'fxmanifest.lua'), manifest);
  return dir;
}

function run(args) {
  let out = '';
  let err = '';
  const code = main(args, { out: (s) => (out += s), err: (s) => (err += s) });
  return { code, out, err };
}

const rm = (dir) => fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });

test('the lexer blanks comments and long strings but keeps quoted strings, even with dashes inside', () => {
  const text = "a 'x--y' -- gone\nb --[[ long\ncomment ]] c \"p--q\" [[ text ]] d --[==[ z ]==] e";
  const { code, longStrings } = lex(text);
  assert.equal(code.length, text.length);
  assert.ok(code.includes("'x--y'"), 'dashes inside a string are not a comment');
  assert.ok(code.includes('"p--q"'));
  assert.ok(!code.includes('gone') && !code.includes('long') && !code.includes('text') && !code.includes(' z '));
  assert.equal(longStrings, 1);
  assert.equal(code.split('\n').length, text.split('\n').length, 'line numbers are preserved');
});

test('strings that continue over several lines are read the way Lua reads them', () => {
  // \z skips all following white space, line breaks included: the include below is INSIDE the string
  const hidden = "description \"x\\z\n   shared_script '@torii/init.lua' \"\nserver_script 'a.lua'\n";
  assert.equal(inspectManifest(hidden).installed, false, 'text inside a \\z string is not a directive');
  assert.equal(inspectManifest(hidden).hasServerCode, true);
  assert.equal(inspectManifest(hidden).uncertain, false);

  // a backslash before CRLF, LFCR or LF continues the string as well
  for (const eol of ['\r\n', '\n\r', '\n', '\r']) {
    const text = `description "x\\${eol}shared_script '@torii/init.lua'"${eol}server_script 'a.lua'${eol}`;
    assert.equal(inspectManifest(text).installed, false, JSON.stringify(eol));
  }

  // the real directive after such a string is still found
  const real = "description 'a\\z\n   b'\nshared_script '@torii/init.lua'\nserver_script 'a.lua'\n";
  assert.equal(inspectManifest(real).installed, true);

  // an unterminated string is not valid Lua: report the manifest as unreadable
  assert.equal(inspectManifest("description 'oops\nserver_script 'a.lua'\n").uncertain, true);
  assert.equal(lex("'a\\z\n  b'").longStrings, 0);
  assert.equal(lex("'open").unterminated, 1);
  assert.equal(lex("'a\\z\n  b' c").code.length, "'a\\z\n  b' c".length, 'offsets are preserved');
});

test('only the first shared script counts as the torii include', () => {
  const server = "server_script 'server.lua'\n";
  assert.equal(inspectManifest("fx_version 'cerulean'\nshared_script '@torii/init.lua'\n" + server).installed, true);
  assert.equal(inspectManifest("shared_scripts { '@torii/init.lua', 'a.lua' }\n" + server).installed, true);
  assert.equal(inspectManifest("shared_script('@torii/init.lua')\n" + server).installed, true);

  const late = inspectManifest("shared_script 'config.lua'\nshared_script '@torii/init.lua'\n" + server);
  assert.equal(late.installed, false, 'present but not first is not protected');
  assert.equal(late.presentButNotFirst, true);

  assert.equal(inspectManifest("-- shared_script '@torii/init.lua'\n" + server).installed, false, 'commented out');
  assert.equal(inspectManifest("--[[\nshared_script '@torii/init.lua'\n]]\n" + server).installed, false, 'block comment');
  assert.equal(inspectManifest("description \"shared_script '@torii/init.lua'\"\n" + server).installed, false, 'inside a string');
});

test('manifests that cannot be read with confidence are reported as uncertain', () => {
  const server = "server_script 'server.lua'\n";
  assert.equal(inspectManifest("fx_version 'cerulean'\n" + server).uncertain, false);
  assert.equal(inspectManifest("shared_scripts {\n  'a.lua',\n}\n" + server).uncertain, false);
  assert.equal(inspectManifest("server_script [[server.lua]]\n").uncertain, true, 'long string');
  assert.equal(inspectManifest("local f = 'server'\nserver_script(f .. '.lua')\n").uncertain, true, 'computed');
  assert.equal(inspectManifest('server_script some_variable\n').uncertain, true, 'not a literal');
  assert.equal(inspectManifest("for _, f in ipairs({ 'a' }) do server_script(f) end\n").uncertain, true, 'loop');
});

test('install leaves an uncertain manifest alone and status says so', () => {
  const root = tempDir();
  try {
    const dir = writeResource(root, 'computed', "local f = 'server'\nserver_script(f .. '.lua')\n");
    const before = fs.readFileSync(path.join(dir, 'fxmanifest.lua'), 'utf8');
    const result = run(['install', root]);
    assert.equal(result.code, 0);
    assert.match(result.out, /not touched/);
    assert.match(result.out, /1 need a manual look/);
    assert.equal(fs.readFileSync(path.join(dir, 'fxmanifest.lua'), 'utf8'), before);
    assert.ok(!fs.existsSync(path.join(dir, 'fxmanifest.lua.torii.bak')));
    assert.match(run(['status', root]).out, /unsure: 1/);
  } finally {
    rm(root);
  }
});

test('install refuses to write when the include would not be the first shared script', () => {
  const root = tempDir();
  try {
    const dir = writeResource(root, 'odd', "shared_script 'early.lua'\nfx_version 'cerulean'\nserver_script 'server.lua'\n");
    const before = fs.readFileSync(path.join(dir, 'fxmanifest.lua'), 'utf8');
    const result = run(['install', root]);
    assert.match(result.out, /would not be the first shared script/);
    assert.equal(fs.readFileSync(path.join(dir, 'fxmanifest.lua'), 'utf8'), before);
  } finally {
    rm(root);
  }
});

test('entries are reduced to the form the runtime sees before they are classified', () => {
  const ok = (text) => {
    const parsed = normalizeEntry(text);
    assert.equal(parsed.ok, true, text);
    return parsed;
  };
  assert.deepEqual(ok('HTTPS://Pastebin.COM./raw'), { ok: true, entry: 'pastebin.com/raw', host: 'pastebin.com', hasPath: true });
  assert.equal(ok('pastebin.com:443').entry, 'pastebin.com');
  assert.equal(ok('http://example.com:8080/a/').entry, 'http://example.com:8080/a');
  assert.equal(ok('http://example.com:80').entry, 'http://example.com');
  assert.equal(ok('discord.com/').hasPath, false);
  assert.equal(ok('discord.com/./').hasPath, false);
  assert.equal(ok('discord.com/x/../').hasPath, false);
  assert.equal(ok('discord.com/api/webhooks/1').hasPath, true);
  assert.equal(ok('[2606:4700::1111]:8443/x').host, '2606:4700::1111');

  for (const bad of ['', '   ', '*.example.com', 'https://user@example.com', 'https://exa mple.com', 'ftp://example.com', 'https://ex%61mple.com', 'https://exämple.com', 'example.com\\path']) {
    assert.equal(normalizeEntry(bad).ok, false, JSON.stringify(bad));
  }
  assert.equal(normalizeEntry(42).ok, false);
});

test('approve warns about declared hosts however they are spelled, and drops entries the runtime would ignore', () => {
  const root = tempDir();
  try {
    writeResource(
      root,
      'sneaky',
      [
        "fx_version 'cerulean'",
        "server_script 'server.lua'",
        "torii_http 'HTTPS://Pastebin.com./raw'",
        "torii_http 'discord.com/./'",
        "torii_http 'https://user@evil.example'",
        "torii_http 'discord.com/api/webhooks/123'",
        '',
      ].join('\n'),
    );
    const lockPath = path.join(root, 'lock.json');
    const result = run(['approve', root, '--lock', lockPath]);
    assert.equal(result.code, 0);
    assert.match(result.out, /pastebin\.com serves or receives user content/);
    assert.match(result.out, /discord\.com accepts data from anyone/);
    assert.match(result.out, /would be ignored by torii \(user info is not allowed\)/);
    assert.match(result.out, /\+ http\s+pastebin\.com\/raw/);
    assert.ok(!/\+ http\s+evil\.example/.test(result.out), 'an entry the runtime rejects is not proposed');
    assert.equal((result.out.match(/discord\.com accepts data/g) ?? []).length, 1, 'the scoped webhook does not warn');
  } finally {
    rm(root);
  }
});
