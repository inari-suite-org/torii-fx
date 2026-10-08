// Plain-language verdicts for what `torii approve` proposes: common, check, suspicious. They tell a server owner who is
// not a developer what to look at and what to do. They never grant anything: a suspicious item is left out of the
// lockfile unless the admin asks for it, and "common" means usual, not safe.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { lockDynamic, widerDynamic } from './dynamic.mjs';
import { hostSignals } from './hosts.mjs';
import { covers } from './lock.mjs';
import { hostRisk } from './logs.mjs';
import { normalizeEntry } from './entries.mjs';

export const LEVELS = ['common', 'check', 'suspicious'];
export const LABELS = { common: '🟢 common', check: '🟠 check', suspicious: '🔴 suspicious' };

const COMMON_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'presets', 'common-hosts.json');

/** @returns {{ entry: string, why: string }[]} */
export function loadCommonHosts(file = COMMON_FILE) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return (raw.entries ?? []).filter((item) => typeof item.entry === 'string' && typeof item.why === 'string');
}

const DISCORD = new Set(['discord.com', 'ptb.discord.com', 'canary.discord.com', 'discordapp.com']);
// GET https://api.github.com/repos/<owner>/<repo>/releases/latest: the usual version check of FiveM scripts
const RELEASE_CHECK = /^\/repos\/[A-Za-z0-9-]+\/[A-Za-z0-9._-]+\/releases\/latest$/;

/** @typedef {{ level: 'common'|'check'|'suspicious', why: string, todo: string }} Verdict */

/**
 * @param {string} entry a lockfile http entry (canonical or not)
 * @param {{ common?: { entry: string, why: string }[], preset?: { entry: string, id: string }[] }} context
 * @returns {Verdict}
 */
export function httpVerdict(entry, { common = [], preset = [] } = {}) {
  const parsed = normalizeEntry(entry);
  if (!parsed.ok) return { level: 'suspicious', why: `not a valid address (${parsed.reason})`, todo: 'do not allow' };
  const host = parsed.host;
  const pathPart = parsed.hasPath ? parsed.entry.slice(parsed.entry.indexOf('/', parsed.entry.indexOf('://') + 3)) : '';
  const plainHttp = parsed.entry.startsWith('http://');

  const signals = hostSignals(host);
  if (signals.length > 0) {
    return { level: 'suspicious', why: signals[0], todo: 'do not allow unless you recognise this exact address; real services rarely look like this' };
  }
  if (hostRisk(host) === 'user_content') {
    return {
      level: 'suspicious',
      why: `${host} hosts content anybody can publish, which is where loaders keep their payload`,
      todo: 'do not allow unless the script author explains why the script needs it',
    };
  }
  const fromPreset = preset.find((item) => covers(item.entry, parsed.entry));
  if (fromPreset) return { level: 'common', why: `needed by ${fromPreset.id} (checked against its source)`, todo: 'nothing to do' };
  const known = common.find((item) => covers(item.entry, parsed.entry));
  if (known) return { level: 'common', why: known.why, todo: 'nothing to do' };
  if (host === 'api.github.com' && RELEASE_CHECK.test(pathPart)) {
    return { level: 'common', why: 'version check: reads the latest release of one GitHub repository', todo: 'nothing to do' };
  }
  if (DISCORD.has(host)) {
    if (!pathPart.startsWith('/api/webhooks/')) {
      return { level: 'check', why: 'Discord without a webhook path lets the script post anywhere on Discord', todo: 'allow only your own webhook address (discord.com/api/webhooks/<number>)' };
    }
    return {
      level: 'check',
      why: 'a Discord webhook receives whatever the script sends; a backdoor sends your secrets to its own webhook',
      todo: 'allow only if it is yours: Discord > Server Settings > Integrations > Webhooks must list this number',
    };
  }
  if (hostRisk(host) === 'shared_api') {
    return { level: 'check', why: `${host} accepts data from anyone with an account`, todo: 'allow only if the account in the address is yours or the script author\'s' };
  }
  if (plainHttp) {
    return { level: 'check', why: `${host} is reached without encryption (http://)`, todo: 'ask the script author why it does not use https' };
  }
  return { level: 'check', why: `torii does not know ${host}`, todo: 'ask the script author what it is for before allowing it' };
}

/**
 * @param {import('./dynamic.mjs').DynamicLevel} level what is about to be granted
 * @param {{ fromPreset?: string, memoryLoads?: boolean }} context memoryLoads: the logs show load() on text that did
 *   not come from the resource's files
 * @returns {Verdict | null} null when nothing is granted
 */
export function dynamicVerdict(level, { fromPreset, memoryLoads = false } = {}) {
  if (!level) return null;
  if (level === 'files') {
    return { level: 'common', why: 'runs only code read from its own files, as module loaders such as ox_lib do', todo: 'nothing to do' };
  }
  if (fromPreset) return { level: 'common', why: `needed by ${fromPreset} (checked against its source)`, todo: 'nothing to do' };
  if (memoryLoads) {
    return {
      level: 'suspicious',
      why: 'ran code it built in memory or received, not code from its own files: this is how remote loaders work',
      todo: 'do not allow unless the script author explains why',
    };
  }
  return { level: 'check', why: 'may run any text as code', todo: 'prefer torii_dynamic_code \'files\' if the script only loads its own files; ask the author otherwise' };
}

/** Running arbitrary code and reaching a destination that is not common: how a download-and-run loader looks. */
export function loaderShape({ http, dynamic }) {
  return dynamic !== null && dynamic.level !== 'common' && http.some((item) => item.verdict.level !== 'common');
}

/**
 * One verdict per resource: the worst of its items, raised to suspicious for the loader shape.
 * @param {{ http: { entry: string, verdict: Verdict }[], dynamic: Verdict | null }} items
 * @returns {'common'|'check'|'suspicious'}
 */
export function resourceLevel(items) {
  const all = [...items.http.map((item) => item.verdict), ...(items.dynamic ? [items.dynamic] : [])];
  let worst = 0;
  for (const verdict of all) worst = Math.max(worst, LEVELS.indexOf(verdict.level));
  if (loaderShape(items)) worst = 2;
  return LEVELS[worst];
}

/**
 * Gives a verdict to every item `additions` would add to `lock`, and takes the suspicious ones out of `additions`
 * unless `keepSuspicious` (the admin can still add them on purpose). Items already granted are not reviewed again.
 * @param {{ resources: Record<string, { http: string[], dynamic_code: import('./dynamic.mjs').DynamicLevel }> }} lock
 * @param {Record<string, { http: string[], dynamic_code: import('./dynamic.mjs').DynamicLevel }>} additions changed in place
 * @param {{ presetGrants?: Record<string, { id: string, grants: { http: string[], dynamic_code: boolean } }>,
 *   memoryLoads?: Set<string>, keepSuspicious?: boolean, common?: { entry: string, why: string }[] }} options
 */
export function reviewAdditions(lock, additions, options = {}) {
  const { presetGrants = {}, memoryLoads = new Set(), keepSuspicious = false, common = loadCommonHosts() } = options;
  const review = [];
  for (const [name, add] of Object.entries(additions)) {
    const granted = lock.resources[name];
    const preset = presetGrants[name];
    const presetHttp = (preset?.grants.http ?? []).map((entry) => ({ entry, id: preset.id }));
    const http = add.http
      .filter((entry) => !granted?.http.includes(entry))
      .map((entry) => ({ entry, verdict: httpVerdict(entry, { common, preset: presetHttp }) }));
    const current = lockDynamic(granted?.dynamic_code);
    const wanted = widerDynamic(current, add.dynamic_code);
    const dynamic =
      wanted === current
        ? null
        : dynamicVerdict(wanted, { fromPreset: preset?.grants.dynamic_code ? preset.id : undefined, memoryLoads: memoryLoads.has(name) });
    if (http.length === 0 && dynamic === null) continue;

    const leftOut = { http: [], dynamic: false };
    if (!keepSuspicious) {
      leftOut.http = http.filter((item) => item.verdict.level === 'suspicious').map((item) => item.entry);
      add.http = add.http.filter((entry) => !leftOut.http.includes(entry));
      if (dynamic?.level === 'suspicious') {
        leftOut.dynamic = true;
        add.dynamic_code = current;
      }
    }
    const covered = http.flatMap((item) => {
      const host = normalizeEntry(item.entry).host ?? '';
      return [`${host} serves or receives user content`, `${host} accepts data from anyone`];
    });
    if (dynamic) covered.push('dynamic_code lets this resource run any text');
    const items = { http, dynamic };
    review.push({ name, level: resourceLevel(items), loader: loaderShape(items), http, dynamic, wanted, leftOut, covered });
  }
  return review.sort((a, b) => LEVELS.indexOf(b.level) - LEVELS.indexOf(a.level) || a.name.localeCompare(b.name));
}

/** The review as text lines, worst first. */
export function reviewLines(review) {
  const lines = [];
  const detail = (verdict, leftOut) => {
    lines.push(`         why   ${verdict.why}`);
    if (verdict.level !== 'common') lines.push(`         do    ${verdict.todo}`);
    if (leftOut) lines.push('         left out of the proposal (add --include-suspicious to keep it)');
  };
  for (const item of review) {
    lines.push(`${LABELS[item.level]}  ${item.name}`);
    for (const { entry, verdict } of item.http) {
      lines.push(`    ${LABELS[verdict.level]}  http ${entry}`);
      detail(verdict, item.leftOut.http.includes(entry));
    }
    if (item.dynamic) {
      lines.push(`    ${LABELS[item.dynamic.level]}  dynamic_code ${item.wanted === 'files' ? "'files'" : 'yes'}`);
      detail(item.dynamic, item.leftOut.dynamic);
    }
    if (item.loader) {
      lines.push('    🔴 together: runs code it was not shipped with and talks to a destination torii cannot vouch for, the shape of a');
      lines.push('       download-and-run loader. Check this script before allowing anything.');
    }
    lines.push('');
  }
  while (lines.at(-1) === '') lines.pop();
  return lines;
}
