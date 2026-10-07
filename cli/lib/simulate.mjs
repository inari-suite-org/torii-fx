// Replaying observe-mode events against a lockfile: what would enforce mode block, and why.
//
// The runtime log keeps only a safe summary of each request (no query string, at most three path segments, long
// opaque segments replaced by <redacted>). So a path-prefix entry longer than what the log kept cannot always be
// decided: those cases are reported as "cannot tell" instead of being guessed.

import { normalizeEntry } from './entries.mjs';
import { isSafeResourceName } from './names.mjs';

/** Reasons that no lockfile can change: torii refuses these targets and actions in enforce mode whatever it says. */
const ALWAYS_REFUSED = new Set([
  'loopback_address', 'private_address', 'link_local_address', 'local_name', 'single_label_host', 'unspecified_address',
  'shared_address_space', 'reserved_address', 'multicast_or_reserved_address', 'ipv4_embedded_address',
  'binary_chunk_refused', 'manifest_write',
]);

const BLOCKING_DECISIONS = new Set(['deny', 'would_deny']);

/** Splits a logged target ("https://host:8443/a/<redacted>") into what is known about it. */
export function parseLoggedTarget(target) {
  const parsed = normalizeEntry(String(target ?? '').replace('<redacted>', 'x-redacted-x'));
  if (!parsed.ok) return null;
  const match = /^(https?):\/\//i.exec(String(target));
  const scheme = match ? match[1].toLowerCase() : 'https';
  const afterHost = String(target).replace(/^https?:\/\/[^/]+/i, '');
  const segments = afterHost.split('/').filter(Boolean);
  const redactedAt = segments.indexOf('<redacted>');
  const known = redactedAt === -1 ? segments : segments.slice(0, redactedAt);
  return {
    scheme,
    hostPort: parsed.entry.replace(/^http:\/\//, '').split('/')[0],
    knownSegments: known,
    // the runtime keeps at most three segments, and stops at the first token-like one
    truncated: redactedAt !== -1 || segments.length >= 3,
  };
}

/** Parses a lockfile entry into the same shape as a logged target. */
function parseEntryShape(text) {
  const parsed = normalizeEntry(text);
  if (!parsed.ok) return null;
  const scheme = parsed.entry.startsWith('http://') ? 'http' : 'https';
  const rest = parsed.entry.replace(/^http:\/\//, '');
  const [hostPort, ...segments] = rest.split('/');
  return { scheme, hostPort, segments: segments.filter(Boolean) };
}

/**
 * 'allowed' | 'blocked' | 'unknown' for one logged HTTP target against a list of lockfile entries.
 */
export function judgeHttp(target, entries) {
  const logged = parseLoggedTarget(target);
  if (!logged) return 'blocked';
  let unknown = false;
  for (const text of entries) {
    const entry = parseEntryShape(text);
    if (!entry || entry.scheme !== logged.scheme || entry.hostPort !== logged.hostPort) continue;
    const prefix = entry.segments;
    const shared = Math.min(prefix.length, logged.knownSegments.length);
    let same = true;
    for (let i = 0; i < shared; i += 1) if (prefix[i] !== logged.knownSegments[i]) same = false;
    if (!same) continue;
    if (prefix.length <= logged.knownSegments.length) return 'allowed';
    if (logged.truncated) unknown = true; // the entry is longer than what the log kept
  }
  return unknown ? 'unknown' : 'blocked';
}

/**
 * @param {object[]} events parsed JSON-lines events
 * @param {{ resources: Record<string, { http: string[], dynamic_code: boolean }>, exempt: string[] }} lock
 */
export function simulate(events, lock) {
  const outcomes = new Map();
  for (const event of events) {
    const resource = event.resource;
    if (!BLOCKING_DECISIONS.has(event.decision) || !isSafeResourceName(resource)) continue;
    const grant = lock.resources[resource];
    let verdict;
    let why = event.reason;
    let subject = resource;
    if (event.type === 'manifest_gate') {
      subject = String(event.target ?? '');
      verdict = lock.exempt.includes(subject) ? 'allowed' : 'blocked';
      if (verdict === 'allowed') why = 'exempt';
    } else if (ALWAYS_REFUSED.has(event.reason) || String(event.reason ?? '').startsWith('invalid_url')) {
      verdict = 'blocked';
    } else if (event.type === 'http') {
      verdict = grant ? judgeHttp(event.target, grant.http) : 'blocked';
      if (!grant) why = 'resource_not_in_lockfile';
      else if (verdict === 'blocked') why = 'not_in_allow_list';
    } else if (event.type === 'dynamic_code') {
      verdict = grant?.dynamic_code ? 'allowed' : 'blocked';
      why = grant ? 'dynamic_code_not_granted' : 'resource_not_in_lockfile';
    } else {
      continue;
    }
    const key = `${subject}\u0000${event.type}\u0000${event.target}\u0000${verdict}`;
    const current = outcomes.get(key);
    if (current) current.count += 1;
    else outcomes.set(key, { resource: subject, type: event.type, target: String(event.target ?? ''), reason: why, verdict, count: 1 });
  }
  return [...outcomes.values()].sort((a, b) => a.resource.localeCompare(b.resource) || b.count - a.count);
}
