#!/usr/bin/env node
// Differential test: torii's URL parser (torii/src/url.lua) against libcurl, which FXServer uses to send requests.
//
// The property that matters: whenever torii ACCEPTS a URL, curl must read the same scheme, host and port. If they
// differ, torii's policy would judge one host while curl connects to another: a bypass.
//
// No request leaves the machine: every connection is diverted to 127.0.0.1:9 (closed) with --connect-to, proxies
// are disabled, and curl only reports how it parsed the URL (%{url.*}).
//
//   node research/url-differential/run.mjs [count] [seed]     (from the repository root; needs lua and curl >= 8.1)

import { spawn, spawnSync } from 'node:child_process';

const COUNT = Number(process.argv[2] ?? 3000);
let seed = Number(process.argv[3] ?? 20261008) >>> 0;

// Small deterministic PRNG (mulberry32) so a failing case can be reproduced from its seed.
function random() {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (list) => list[Math.floor(random() * list.length)];

const SCHEMES = ['https://', 'http://', 'HTTPS://', 'HtTp://', 'https:/', 'https:\\\\', 'https:///', 'https:'];
const USERINFO = ['', '', '', 'user@', 'a:b@', '@', 'evil.example@', 'good.example:x@'];
const HOSTS = [
  'example.com', 'Example.COM.', 'api.example.com', 'example.com.', 'xn--e1afmkfd.xn--p1ai', 'localhost', 'LOCALHOST.',
  '127.0.0.1', '127.1', '2130706433', '0x7f000001', '0177.0.0.1', '0x7f.0.0.1', '127.0.0.1.', '1.2.3', '0.0.0.0',
  '169.254.169.254', '8.8.8.8', '08.8.8.8', '0x08.8.8.8', '1.1.1.1.1', '4294967295', '4294967296', '00000000127.1',
  '[::1]', '[::ffff:127.0.0.1]', '[0:0:0:0:0:ffff:7f00:1]', '[2606:4700:4700::1111]', '[::ffff:7f00:0001]',
  'example.com%2e', 'exa%6dple.com', 'example..com', '.example.com', 'exa_mple.com', 'example.com\\@evil.example',
  'example.com#@evil.example', 'example.com?@evil.example', 'example.com;evil.example', 'éxample.com', 'example.c0m',
  'a.users.cfx.re', 'evil.example\\.example.com', '0', '1', 'example',
];
const PORTS = ['', '', '', ':80', ':443', ':8080', ':', ':0', ':65535', ':65536', ':00080', ':+80', ':0x50', ':1e2'];
const PATHS = ['', '/', '/a', '/a/../b', '/%2e%2e/x', '?q=1', '#frag', '/a?x=@evil.example', '/\\evil', '//evil.example/x'];
const NOISE = [' ', '\t', '\\', '%', '@', '#', '?', '.', '[', ']', ':', '/', '%00', '%2f', '%40', '。', '．'];

function generate() {
  let text = pick(SCHEMES) + pick(USERINFO) + pick(HOSTS) + pick(PORTS) + pick(PATHS);
  if (random() < 0.35) {
    const at = Math.floor(random() * (text.length + 1));
    text = text.slice(0, at) + pick(NOISE) + text.slice(at);
  }
  if (random() < 0.2) {
    text = [...text].map((ch) => (random() < 0.3 ? ch.toUpperCase() : ch)).join('');
  }
  return text;
}

const urls = [...new Set(Array.from({ length: COUNT }, generate))];

// 1. torii, all at once
const hex = urls.map((u) => Buffer.from(u, 'utf8').toString('hex')).join('\n') + '\n';
const lua = spawnSync('lua', ['research/url-differential/torii_parse.lua'], { input: hex, encoding: 'utf8' });
if (lua.status !== 0) throw new Error(`lua failed: ${lua.stderr}`);
const torii = lua.stdout.trim().split(/\r?\n/).map((line) => line.split('\t'));

// 2. curl, a few at a time
function curlParse(target) {
  return new Promise((resolve) => {
    const child = spawn('curl', [
      // -g: no curl globbing, so [ ] { } are read as URL characters like FXServer's libcurl does
      '-s', '-g', '-o', process.platform === 'win32' ? 'NUL' : '/dev/null',
      '--noproxy', '*', '--connect-to', '::127.0.0.1:9', '--max-time', '2', '--proto', '=http,https',
      '-w', '%{url.scheme}\t%{url.host}\t%{url.port}\t%{url.user}',
      '--', target,
    ]);
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.on('close', (code) => resolve({ code, parts: out.split('\t') }));
    child.on('error', () => resolve({ code: -1, parts: [] }));
  });
}

const results = new Array(urls.length);
let next = 0;
async function worker() {
  while (next < urls.length) {
    const index = next++;
    results[index] = await curlParse(urls[index]);
  }
}
await Promise.all(Array.from({ length: 8 }, worker));

// 3. compare
const normHost = (h) => (h ?? '').toLowerCase().replace(/\.$/, '').replace(/^\[|\]$/g, '');
const findings = { bypass: [], toriiOnly: [], stricter: 0, agree: 0 };
urls.forEach((target, i) => {
  const t = torii[i];
  const c = results[i];
  // curl exit 3 = malformed URL, 1 = unsupported protocol: curl would not send anything
  const curlUnderstood = c.code !== 3 && c.code !== 1 && c.code !== -1 && c.parts[1];
  if (t[0] !== 'ok') {
    if (curlUnderstood) findings.stricter += 1;
    return;
  }
  if (!curlUnderstood) {
    findings.toriiOnly.push({ target, torii: t.slice(1), curlExit: c.code });
    return;
  }
  const [cScheme, cHost, cPort] = c.parts;
  const same = t[1] === cScheme.toLowerCase() && normHost(t[2]) === normHost(cHost) && t[3] === cPort;
  if (same) findings.agree += 1;
  else findings.bypass.push({ target, torii: t.slice(1, 4), curl: [cScheme, cHost, cPort], curlUser: c.parts[3] });
});

console.log(`urls: ${urls.length}`);
console.log(`both accept and agree: ${findings.agree}`);
console.log(`torii rejects, curl accepts (torii stricter, fine): ${findings.stricter}`);
console.log(`torii accepts, curl rejects (no request is sent, review): ${findings.toriiOnly.length}`);
console.log(`torii accepts, curl reads a different scheme/host/port (BYPASS): ${findings.bypass.length}`);
for (const f of findings.bypass.slice(0, 30)) console.log('  BYPASS', JSON.stringify(f));
for (const f of findings.toriiOnly.slice(0, 10)) console.log('  torii-only', JSON.stringify(f));
process.exitCode = findings.bypass.length > 0 ? 1 : 0;
