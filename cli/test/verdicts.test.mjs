import assert from 'node:assert/strict';
import { test } from 'node:test';
import { normalizeEntry } from '../lib/entries.mjs';
import { hostRisk } from '../lib/logs.mjs';
import { dynamicVerdict, httpVerdict, loadCommonHosts, resourceLevel, reviewAdditions, reviewLines } from '../lib/verdicts.mjs';

const common = loadCommonHosts();
const level = (entry, context = { common }) => httpVerdict(entry, context).level;

test('http verdicts: suspicious shapes', () => {
  assert.equal(level('45.133.1.20'), 'suspicious');
  assert.equal(level('http://45.133.1.20:8080/x'), 'suspicious');
  assert.equal(level('dlscord.com/api/webhooks/1'), 'suspicious', 'one letter away from discord.com');
  assert.equal(level('xn--dscord-6ve.com'), 'suspicious', 'punycode');
  assert.equal(level('pastebin.com/raw'), 'suspicious');
  assert.equal(level('raw.githubusercontent.com/someone/repo'), 'suspicious');
  assert.match(httpVerdict('pastebin.com').todo, /do not allow/);
});

test('http verdicts: common only for scoped, read-only, known destinations', () => {
  assert.equal(level('api.github.com/repos/overextended'), 'common');
  assert.equal(level('api.github.com/repos/overextended/ox_lib/releases/latest'), 'common');
  assert.equal(level('api.github.com/repos/some-author/some_script/releases/latest'), 'common', 'a version check');
  assert.equal(level('api.github.com/repos/some-author/some_script/contents/payload.lua'), 'check', 'not a version check');
  assert.equal(level('api.github.com'), 'check');
  const preset = [{ entry: 'api.example.com/v1', id: 'example_lib' }];
  const verdict = httpVerdict('api.example.com/v1/items', { common, preset });
  assert.equal(verdict.level, 'common');
  assert.match(verdict.why, /example_lib/);
});

test('http verdicts: data-receiving services and unknown hosts need a human', () => {
  const webhook = httpVerdict('discord.com/api/webhooks/123', { common });
  assert.equal(webhook.level, 'check');
  assert.match(webhook.todo, /Integrations > Webhooks/);
  assert.match(httpVerdict('discord.com', { common }).why, /without a webhook path/);
  assert.match(httpVerdict('http://weather.example/v1', { common }).why, /without encryption/);
  const unknown = httpVerdict('api.weather.example/v1', { common });
  assert.equal(unknown.level, 'check');
  assert.match(unknown.todo, /ask the script author/);
});

test('dynamic code verdicts', () => {
  assert.equal(dynamicVerdict(false), null);
  assert.equal(dynamicVerdict('files').level, 'common');
  assert.equal(dynamicVerdict(true, { fromPreset: 'ox_lib' }).level, 'common');
  assert.equal(dynamicVerdict(true, { memoryLoads: true }).level, 'suspicious');
  assert.equal(dynamicVerdict(true).level, 'check');
});

test('running any code and reaching an unknown host is the loader shape', () => {
  const unknown = { entry: 'api.weather.example', verdict: httpVerdict('api.weather.example', { common }) };
  const known = { entry: 'api.github.com/repos/overextended', verdict: httpVerdict('api.github.com/repos/overextended', { common }) };
  assert.equal(resourceLevel({ http: [unknown], dynamic: dynamicVerdict(true) }), 'suspicious');
  assert.equal(resourceLevel({ http: [unknown], dynamic: dynamicVerdict('files') }), 'check');
  assert.equal(resourceLevel({ http: [known], dynamic: dynamicVerdict(true) }), 'check');
  assert.equal(resourceLevel({ http: [known], dynamic: null }), 'common');
});

test('review leaves suspicious items out unless asked, and never re-reviews existing grants', () => {
  const lock = { resources: { shop: { http: ['api.shop.example'], dynamic_code: false } } };
  const fresh = () => ({
    shop: { http: ['api.shop.example', '45.133.1.20', 'api.github.com/repos/overextended'], dynamic_code: true },
    lib_user: { http: [], dynamic_code: 'files' },
  });

  const additions = fresh();
  const review = reviewAdditions(lock, additions, { memoryLoads: new Set(['shop']), common });
  assert.deepEqual(additions.shop.http, ['api.shop.example', 'api.github.com/repos/overextended']);
  assert.equal(additions.shop.dynamic_code, false, 'suspicious dynamic code falls back to the current grant');
  assert.equal(additions.lib_user.dynamic_code, 'files');
  assert.deepEqual(review.map((item) => [item.name, item.level]), [['shop', 'suspicious'], ['lib_user', 'common']]);
  const shop = review[0];
  assert.ok(!shop.http.some((item) => item.entry === 'api.shop.example'), 'already granted, not reviewed again');
  assert.deepEqual(shop.leftOut, { http: ['45.133.1.20'], dynamic: true });

  const text = reviewLines(review).join('\n');
  assert.match(text, /^🔴 suspicious {2}shop/);
  assert.match(text, /left out of the proposal/);
  assert.match(text, /🟢 common {2}dynamic_code 'files'/);

  const kept = fresh();
  reviewAdditions(lock, kept, { memoryLoads: new Set(['shop']), keepSuspicious: true, common });
  assert.ok(kept.shop.http.includes('45.133.1.20'));
  assert.equal(kept.shop.dynamic_code, true);
});

test('the common list only holds scoped, read-only destinations with a reason and a source', () => {
  assert.ok(common.length > 0);
  const raw = loadCommonHosts();
  for (const item of raw) {
    const parsed = normalizeEntry(item.entry);
    assert.ok(parsed.ok, item.entry);
    assert.ok(parsed.hasPath, `${item.entry} must be scoped to a path`);
    assert.notEqual(hostRisk(parsed.host), 'user_content', `${item.entry} serves anybody's content`);
    assert.ok(item.why.length > 10, item.entry);
    assert.ok(String(item.source ?? '').startsWith('https://'), `${item.entry} needs a source`);
  }
});
