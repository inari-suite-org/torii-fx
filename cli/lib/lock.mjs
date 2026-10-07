// Lockfile (torii/policy.lock.json): read, merge a proposal, diff, write.

import fs from 'node:fs';
import path from 'node:path';
import { isSafeResourceName } from './names.mjs';

export const LOCK_VERSION = 1;

/** @typedef {{ http: string[], dynamic_code: boolean, follow_redirects: boolean, declaration_hash?: string }} Grant */
/** @typedef {{ version: number, exempt: string[], resources: Record<string, Grant> }} Lock */

/** @returns {Lock} */
export function emptyLock() {
  return { version: LOCK_VERSION, exempt: [], resources: {} };
}

/** @returns {Lock} */
export function readLock(file) {
  if (!fs.existsSync(file)) return emptyLock();
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (raw.version !== LOCK_VERSION) throw new Error(`${file}: unsupported lockfile version ${raw.version}`);
  const lock = emptyLock();
  lock.exempt = Array.isArray(raw.exempt) ? raw.exempt.filter((x) => typeof x === 'string') : [];
  for (const [name, item] of Object.entries(raw.resources ?? {})) {
    if (!isSafeResourceName(name)) continue;
    lock.resources[name] = {
      http: Array.isArray(item.http) ? item.http.filter((x) => typeof x === 'string') : [],
      dynamic_code: item.dynamic_code === true,
      follow_redirects: item.follow_redirects === true,
      ...(typeof item.declaration_hash === 'string' ? { declaration_hash: item.declaration_hash } : {}),
    };
  }
  return lock;
}

/** Deterministic serialisation so lockfile diffs in git stay small. */
export function serializeLock(lock) {
  const resources = {};
  for (const name of Object.keys(lock.resources).sort()) {
    const grant = lock.resources[name];
    resources[name] = {
      http: [...grant.http].sort(),
      dynamic_code: grant.dynamic_code,
      follow_redirects: grant.follow_redirects,
      ...(grant.declaration_hash ? { declaration_hash: grant.declaration_hash } : {}),
    };
  }
  return `${JSON.stringify({ version: LOCK_VERSION, exempt: [...lock.exempt].sort(), resources }, null, 2)}\n`;
}

export function writeLock(file, lock) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, serializeLock(lock));
  fs.renameSync(tmp, file);
}

/**
 * Applies proposed additions to a lock without ever removing an existing grant.
 * @param {Lock} lock
 * @param {Record<string, { http?: string[], dynamic_code?: boolean, follow_redirects?: boolean, declaration_hash?: string }>} additions
 * @returns {Lock}
 */
export function mergeAdditions(lock, additions) {
  const next = structuredClone(lock);
  for (const [name, add] of Object.entries(additions)) {
    if (!isSafeResourceName(name)) continue;
    const current = next.resources[name] ?? { http: [], dynamic_code: false, follow_redirects: false };
    current.http = [...new Set([...current.http, ...(add.http ?? [])])];
    current.dynamic_code = current.dynamic_code || add.dynamic_code === true;
    current.follow_redirects = current.follow_redirects || add.follow_redirects === true;
    if (add.declaration_hash) current.declaration_hash = add.declaration_hash;
    next.resources[name] = current;
  }
  return next;
}

/**
 * Human-readable diff between two locks, as lines. Prefix: "+" added, "~" changed resource,
 * "!" warning that needs a human decision.
 * @returns {string[]}
 */
export function diffLocks(before, after) {
  const lines = [];
  for (const name of Object.keys(after.resources).sort()) {
    const a = after.resources[name];
    const b = before.resources[name];
    const detail = [];
    for (const entry of a.http) if (!b?.http.includes(entry)) detail.push(`    + http              ${entry}`);
    if (a.dynamic_code && !b?.dynamic_code) detail.push('    + dynamic_code      true   (resource may run load() on text)');
    if (a.follow_redirects && !b?.follow_redirects) detail.push('    + follow_redirects  true   (redirects are followed again)');
    if (a.declaration_hash !== b?.declaration_hash) {
      detail.push(`    ~ declaration_hash  ${b?.declaration_hash?.slice(0, 12) ?? '-'} -> ${a.declaration_hash?.slice(0, 12) ?? '-'}`);
    }
    if (detail.length > 0) lines.push(`${b ? '~' : '+'} ${name}`, ...detail);
  }
  return lines;
}
