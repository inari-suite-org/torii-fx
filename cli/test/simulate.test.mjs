import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { editDistance, entropy, hostSignals } from '../lib/hosts.mjs';
import { explainReason } from '../lib/reasons.mjs';
import { judgeHttp, parseLoggedTarget, simulate } from '../lib/simulate.mjs';
import { main } from '../torii.mjs';

const rm = (dir) => fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });

function run(args) {
  let out = '';
  let err = '';
  const code = main(args, { out: (s) => (out += s), err: (s) => (err += s) });
  return { code, out, err };
}

const lock = (resources, exempt = []) => ({ version: 1, exempt, resources });

test('a logged target keeps only what the runtime log keeps', () => {
  assert.deepEqual(parseLoggedTarget('https://api.example.com/v1/users'), {
    scheme: 'https',
    hostPort: 'api.example.com',
    knownSegments: ['v1', 'users'],
    truncated: false,
  });
  const webhook = parseLoggedTarget('https://discord.com/api/webhooks/<redacted>');
  assert.deepEqual(webhook.knownSegments, ['api', 'webhooks']);
  assert.equal(webhook.truncated, true);
  assert.equal(parseLoggedTarget('http://legacy.example:8080/a').hostPort, 'legacy.example:8080');
  assert.equal(parseLoggedTarget('<unparseable url>'), null);
});

test('judging a logged target against lockfile entries', () => {
  assert.equal(judgeHttp('https://api.example.com/v1/users', ['api.example.com']), 'allowed');
  assert.equal(judgeHttp('https://api.example.com/v1/users', ['api.example.com/v1']), 'allowed');
  assert.equal(judgeHttp('https://api.example.com/v2/users', ['api.example.com/v1']), 'blocked');
  assert.equal(judgeHttp('https://api.example.com/v1/users', ['http://api.example.com']), 'blocked', 'scheme matters');
  assert.equal(judgeHttp('https://api.example.com:8443/v1', ['api.example.com']), 'blocked', 'port matters');
  assert.equal(judgeHttp('https://evil.example/x', ['api.example.com']), 'blocked');
  // the log stopped at a token: an entry that goes deeper cannot be decided
  assert.equal(judgeHttp('https://discord.com/api/webhooks/<redacted>', ['discord.com/api/webhooks/123']), 'unknown');
  assert.equal(judgeHttp('https://discord.com/api/webhooks/<redacted>', ['discord.com/api/webhooks']), 'allowed');
  assert.equal(judgeHttp('https://discord.com/api/webhooks/<redacted>', ['discord.com/api/other']), 'blocked');
});

test('simulate counts what enforce mode would do with a lockfile', () => {
  const events = [
    { resource: 'shop', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://api.example.com/v1' },
    { resource: 'shop', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://api.example.com/v1' },
    { resource: 'shop', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://evil.example/x' },
    { resource: 'shop', type: 'http', decision: 'would_deny', reason: 'loopback_address', target: 'http://127.0.0.1/' },
    { resource: 'shop', type: 'dynamic_code', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'chunk' },
    { resource: 'shop', type: 'bytecode', decision: 'deny', reason: 'binary_chunk_refused', target: 'bytecode' },
    { resource: 'torii', type: 'manifest_gate', decision: 'would_deny', reason: 'unsupported_runtime_js_or_csharp', target: 'oxmysql' },
    { resource: 'shop', type: 'convar', decision: 'allow', reason: 'sensitive_name', target: 'rcon_password' },
    { resource: '__proto__', type: 'http', decision: 'would_deny', reason: 'x', target: 'https://a.example/' },
  ];
  const outcomes = simulate(events, lock({ shop: { http: ['api.example.com'], dynamic_code: true } }, ['oxmysql']));
  const find = (target) => outcomes.find((o) => o.target === target);
  assert.equal(find('https://api.example.com/v1').verdict, 'allowed');
  assert.equal(find('https://api.example.com/v1').count, 2, 'identical events are grouped');
  assert.equal(find('https://evil.example/x').verdict, 'blocked');
  assert.equal(find('https://evil.example/x').reason, 'not_in_allow_list');
  assert.equal(find('http://127.0.0.1/').verdict, 'blocked', 'no lockfile can allow loopback');
  assert.equal(find('chunk').verdict, 'allowed');
  assert.equal(find('bytecode').verdict, 'blocked', 'bytecode is never allowed');
  assert.equal(find('oxmysql').verdict, 'allowed', 'exempt resources pass the gate');
  assert.equal(find('rcon_password'), undefined, 'events that were allowed anyway are not replayed');
  assert.equal(outcomes.some((o) => o.resource === '__proto__'), false);
});

test('a gate event forged by a resource is ignored', () => {
  const events = [
    { resource: 'evil', type: 'manifest_gate', decision: 'would_deny', reason: 'missing_torii_init_line', target: 'oxmysql' },
    { resource: 'torii', type: 'manifest_gate', decision: 'would_deny', reason: 'missing_torii_init_line', target: 'bad name
fake line' },
    { resource: 'torii', type: 'manifest_gate', decision: 'would_deny', reason: 'missing_torii_init_line', target: 'real_one' },
  ];
  const outcomes = simulate(events, lock({}, ['oxmysql']));
  assert.deepEqual(outcomes.map((o) => o.resource), ['real_one']);
});

test('every reason torii logs has an explanation and a next step', () => {
  for (const reason of ['resource_not_in_lockfile', 'not_in_allow_list', 'dynamic_code_not_granted', 'loopback_address', 'private_address', 'binary_chunk_refused', 'manifest_write', 'missing_torii_init_line', 'unsupported_runtime_js_or_csharp', 'declaration_changed_since_approval', 'protected_resource_never_reported', 'invalid_url:userinfo_not_allowed']) {
    const text = explainReason(reason);
    assert.ok(text.why.length > 20, reason);
    assert.ok(text.fix, reason);
  }
  assert.match(explainReason('invalid_url:userinfo_not_allowed').why, /userinfo_not_allowed/);
});

test('host signals: look-alikes, punycode, raw addresses and random labels', () => {
  assert.equal(editDistance('github.com', 'githubb.com'), 1);
  assert.equal(editDistance('discord.com', 'dicsord.com'), 1, 'a transposition counts once');
  assert.ok(entropy('aaaa') === 0 && entropy('abcd') === 2);

  assert.deepEqual(hostSignals('api.github.com'), []);
  assert.deepEqual(hostSignals('discord.com'), []);
  assert.deepEqual(hostSignals('api.weather.example'), []);
  assert.deepEqual(hostSignals('cdn.example.org'), []);
  assert.match(hostSignals('githubb.com').join(), /looks like github\.com/);
  assert.match(hostSignals('dlscord.com').join(), /looks like discord\.com/);
  assert.match(hostSignals('discord.com.evil.example').join(), /contains "discord\.com" but belongs to evil\.example/);
  assert.match(hostSignals('xn--dscord-6ya.com').join(), /punycode/);
  assert.match(hostSignals('203.0.113.7').join(), /raw IP address/);
  assert.match(hostSignals('k3j9x2qz8w7v.top').join(), /randomly generated/);
  assert.match(hostSignals('a8f3k2l9q0w1z.example').join(), /randomly generated/);
});

test('the simulate and explain commands work end to end on a log file', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'torii-sim-'));
  try {
    const log = path.join(root, 'torii.jsonl');
    fs.writeFileSync(
      log,
      [
        { resource: 'shop', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://githubb.com/payload' },
        { resource: 'shop', type: 'http', decision: 'would_deny', reason: 'resource_not_in_lockfile', target: 'https://api.example.com/v1' },
      ]
        .map((e) => JSON.stringify(e))
        .join('\n'),
    );
    const lockPath = path.join(root, 'lock.json');
    fs.writeFileSync(lockPath, JSON.stringify(lock({ shop: { http: ['api.example.com'], dynamic_code: false } })));

    const sim = run(['simulate', root, '--from-logs', log, '--lock', lockPath]);
    assert.equal(sim.code, 0);
    assert.match(sim.out, /shop\s+1\s+1\s+0/);
    assert.match(sim.out, /githubb\.com/);
    assert.equal(run(['simulate', root, '--from-logs', log, '--lock', lockPath, '--fail-on-block']).code, 2);

    const exp = run(['explain', root, '--from-logs', log, '--lock', lockPath, '--resource', 'shop']);
    assert.equal(exp.code, 0);
    assert.match(exp.out, /looks like github\.com/);
    assert.match(exp.out, /"shop": \{ "http": \["githubb\.com\/payload"\] \}/);
    assert.match(exp.out, /allowed by the current lockfile/);

    assert.equal(run(['simulate', root]).code, 1, 'the log is required');
  } finally {
    rm(root);
  }
});
