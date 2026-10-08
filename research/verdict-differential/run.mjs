#!/usr/bin/env node
// Differential test: the verdicts of `torii approve` (cli/lib/verdicts.mjs) against the verdicts of the server console
// (torii/src/verdicts.lua). The two are written separately; an admin must never see "common" on one side and
// "suspicious" on the other for the same destination.
//
// Each generated case is a target as the runtime logs it. The CLI judges the lockfile entry `approve` would propose
// for it, the console judges the target itself; both must give the same level and the same "weak" flag.
//
//   node research/verdict-differential/run.mjs [count] [seed]     (from the repository root; needs lua 5.4)

import { spawnSync } from 'node:child_process';
import { targetToEntry } from '../../cli/lib/logs.mjs';
import { httpVerdict, loadCommonHosts } from '../../cli/lib/verdicts.mjs';
import { KNOWN_DOMAINS } from '../../cli/lib/hosts.mjs';

const COUNT = Number(process.argv[2] ?? 5000);
let seed = Number(process.argv[3] ?? 20261008) >>> 0;

// mulberry32, so a failing case can be reproduced from its seed
function random() {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (list) => list[Math.floor(random() * list.length)];
const ALNUM = 'abcdefghijklmnopqrstuvwxyz0123456789';
const word = (min, max) => Array.from({ length: min + Math.floor(random() * (max - min + 1)) }, () => pick([...ALNUM])).join('');

/** One to two character edits of a known domain's first label: the look-alikes a loader would register. */
function lookalike(domain) {
  const [label, ...rest] = domain.split('.');
  let chars = [...label];
  const edits = 1 + Math.floor(random() * 2);
  for (let i = 0; i < edits; i += 1) {
    const at = Math.floor(random() * chars.length);
    const op = Math.floor(random() * 4);
    if (op === 0) chars[at] = pick([...ALNUM]);
    else if (op === 1) chars.splice(at, 0, pick([...ALNUM]));
    else if (op === 2 && chars.length > 3) chars.splice(at, 1);
    else if (at + 1 < chars.length) [chars[at], chars[at + 1]] = [chars[at + 1], chars[at]];
  }
  return [chars.join(''), ...rest].join('.');
}

const OWNERS = ['overextended', 'Overextended', 'qbcore-framework', 'esx-framework', 'someone', 'loader-dev', 'x'];
const HOSTS = [
  () => pick(KNOWN_DOMAINS),
  () => `${pick(['api', 'cdn', 'www', 'raw'])}.${pick(KNOWN_DOMAINS)}`,
  () => lookalike(pick(KNOWN_DOMAINS)),
  () => `${pick(KNOWN_DOMAINS)}.${word(3, 8)}.com`,
  () => `xn--${word(4, 10)}.com`,
  () => `${Math.floor(random() * 256)}.${Math.floor(random() * 256)}.${Math.floor(random() * 256)}.${Math.floor(random() * 256)}`,
  () => `${word(8, 35)}.${pick(['com', 'net', 'io', 'me'])}`,
  () => `api.${word(3, 9)}.${pick(['com', 'example', 'io'])}`,
  () => pick(['pastebin.com', 'raw.githubusercontent.com', 'x.github.io', 'abc.ngrok-free.app', 'cdn.discordapp.com', 'bit.ly']),
  () => pick(['api.github.com', 'discord.com', 'ptb.discord.com', 'discordapp.com', 'api.telegram.org', 'hooks.slack.com']),
];
const PATHS = [
  () => '',
  () => '/',
  () => `/${word(1, 8)}/${word(1, 8)}`,
  () => `/api/webhooks/${Math.floor(random() * 1e9)}`,
  () => `/api/webhooks/${Math.floor(random() * 1e9)}/<redacted>`,
  () => `/repos/${pick(OWNERS)}/${pick(['ox_lib', 'qb-core', 'es_extended', 'loader', 'a.b_c-d'])}/releases/latest`,
  () => `/repos/${pick(OWNERS)}/x/issues`,
  () => `/repos/${pick(OWNERS)}`,
  () => `/repos/${pick(OWNERS)}/x/releases/latest/<more>`,
  () => `/${word(1, 4)}/${word(1, 4)}/${word(1, 4)}/${word(1, 4)}/${word(1, 4)}/<more>`,
];

function generate() {
  if (random() < 0.15) {
    // GitHub's API on its own: where "common" and "weak" are decided, and where a wrong call would matter most
    const scheme = random() < 0.9 ? 'https' : 'http';
    return `${scheme}://${pick(['api.github.com', 'API.GitHub.com', 'api.github.co', 'api.githubb.com'])}${pick(PATHS.slice(5))()}`;
  }
  const scheme = random() < 0.85 ? 'https' : 'http';
  const port = random() < 0.1 ? `:${pick(['8443', '8080', '30120'])}` : '';
  return `${scheme}://${pick(HOSTS)()}${port}${pick(PATHS)()}`;
}

const targets = [...new Set(Array.from({ length: COUNT }, generate))];
const lua = spawnSync('lua', ['research/verdict-differential/torii_verdict.lua'], { input: `${targets.join('\n')}\n`, encoding: 'utf8' });
if (lua.status !== 0) throw new Error(`lua failed: ${lua.stderr}`);
const console = lua.stdout.trim().split(/\r?\n/).map((line) => line.split('\t'));
const common = loadCommonHosts();

const differences = [];
const levels = { common: 0, check: 0, suspicious: 0 };
targets.forEach((target, i) => {
  const [luaLevel, luaWeak, luaCode] = console[i];
  const converted = targetToEntry(target);
  const cli = converted ? httpVerdict(converted.entry, { common }) : { level: 'suspicious' };
  levels[cli.level] += 1;
  const cliWeak = cli.weak ? 'weak' : '-';
  if (cli.level !== luaLevel || cliWeak !== luaWeak) {
    differences.push(`${target}\n    approve: ${cli.level} ${cliWeak} (${cli.why ?? 'not convertible'})\n    console: ${luaLevel} ${luaWeak} (${luaCode})`);
  }
});

process.stdout.write(`${targets.length} targets  common ${levels.common}  check ${levels.check}  suspicious ${levels.suspicious}\n`);
if (differences.length > 0) {
  process.stdout.write(`${differences.length} difference(s):\n${differences.slice(0, 30).join('\n')}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write('no difference\n');
}
