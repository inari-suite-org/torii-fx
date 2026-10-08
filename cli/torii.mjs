#!/usr/bin/env node
// torii CLI: install / uninstall / status / approve. No dependencies.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { declarationHash, parseDeclaration } from './lib/declaration.mjs';
import { diffLocks, mergeAdditions, readLock, writeLock } from './lib/lock.mjs';
import { proposalFromEvents, readEvents, riskWarning, targetToEntry } from './lib/logs.mjs';
import { hostSignals } from './lib/hosts.mjs';
import { explainReason, FIXES } from './lib/reasons.mjs';
import { simulate } from './lib/simulate.mjs';
import { widerDynamic } from './lib/dynamic.mjs';
import { normalizeEntry } from './lib/entries.mjs';
import { isSafeResourceName } from './lib/names.mjs';
import { appliesTo, describeMatch, loadPresets, matchPresets } from './lib/presets.mjs';
import { findResources, inspectManifest, installInto, isEscrowed, uninstallFrom } from './lib/manifest.mjs';

const HELP = `torii - runtime permission firewall for FiveM Lua resources

Usage:
  torii install   <resources-dir> [--dry-run]     add "shared_script '@torii/init.lua'" to every manifest (backup: *.torii.bak)
  torii uninstall <resources-dir> [--dry-run]     remove the line again
  torii status    <resources-dir>                 which resources are protected, which run JS/C# torii cannot inspect
  torii approve   <resources-dir> [options]       propose lockfile changes as a diff (nothing is written without --write)

  torii simulate  <resources-dir> --from-logs <f> what enforce mode would block with the current lockfile
  torii explain   <resources-dir> --from-logs <f> why each event was blocked, and what to do about it

approve options:
  --from-logs <file>   build the proposal from observe-mode logs (torii/logs/torii.jsonl)
  --lock <file>        lockfile to read/write (default: <resources-dir>/torii/policy.lock.json)
  --use-presets        include the suggestions for well-known libraries (ox_lib, es_extended, ...) in the proposal
  --write              write the proposal to the lockfile (default: print the diff only)

simulate / explain options:
  --lock <file>        lockfile to test (default: <resources-dir>/torii/policy.lock.json)
  --resource <name>    explain: only this resource
  --fail-on-block      simulate: exit with code 2 if anything would still be blocked
`;

/** @param {string[]} argv */
function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      if (['from-logs', 'lock', 'resource'].includes(key)) flags[key] = argv[(i += 1)];
      else flags[key] = true;
    } else {
      positional.push(arg);
    }
  }
  return { positional, flags };
}

function resolveDir(positional, io) {
  const dir = positional[1];
  if (!dir) {
    io.err('Missing <resources-dir>.\n');
    return null;
  }
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
    io.err(`Not a directory: ${dir}\n`);
    return null;
  }
  return path.resolve(dir);
}

function install(dir, flags, io, remove) {
  const resources = findResources(dir);
  const counts = { done: 0, already: 0, skipped: 0, unsure: 0 };
  for (const resource of resources) {
    const label = path.relative(dir, resource.dir) || resource.name;
    if (remove) {
      const result = uninstallFrom(resource, { dryRun: flags['dry-run'] === true });
      if (result === 'removed') {
        counts.done += 1;
        io.out(`  removed    ${label}\n`);
      } else {
        counts.skipped += 1;
      }
      continue;
    }
    const result = installInto(resource, { dryRun: flags['dry-run'] === true });
    if (result === 'installed') {
      counts.done += 1;
      io.out(`  ${flags['dry-run'] ? 'would add ' : 'installed '} ${label}\n`);
      const info = inspectManifest(fs.readFileSync(resource.manifestPath, 'utf8'));
      if (info.jsOrCsharp) io.out(`             note: also has JavaScript/C# server scripts, which torii does NOT cover\n`);
      if (isEscrowed(resource.dir)) io.out(`             note: asset-escrow resource (.fxap); editing its manifest is untested, check it still starts\n`);
    } else if (result === 'already') {
      counts.already += 1;
    } else if (result === 'uncertain') {
      counts.unsure += 1;
      io.out(`  not touched ${label}\n             its manifest uses long strings or computed script lists: add the line by hand\n`);
    } else if (result === 'not-first') {
      counts.unsure += 1;
      io.out(`  not touched ${label}\n             the include would not be the first shared script: place it by hand\n`);
    } else {
      counts.skipped += 1;
    }
  }
  io.out(
    `${resources.length} resources found: ${counts.done} ${remove ? 'restored' : 'changed'}, ` +
      `${counts.already} already protected, ${counts.skipped} skipped (no server code)` +
      `${counts.unsure > 0 ? `, ${counts.unsure} need a manual look` : ''}\n`,
  );
  if (!remove && counts.done > 0 && !flags['dry-run']) {
    io.out('Restart the server. torii starts in observe mode: nothing is blocked until you `set torii_mode "enforce"`.\n');
  }
  return 0;
}

function status(dir, io) {
  const resources = findResources(dir);
  const rows = { protected: [], unprotected: [], unsure: [], noCode: [], jsCs: [] };
  for (const resource of resources) {
    const info = inspectManifest(fs.readFileSync(resource.manifestPath, 'utf8'));
    // A manifest is real Lua: when it cannot be read with confidence the CLI says so instead of guessing.
    if (info.uncertain) rows.unsure.push(resource.name);
    else if (!info.hasServerCode) rows.noCode.push(resource.name);
    else (info.installed ? rows.protected : rows.unprotected).push(resource.name);
    if (info.hasServerCode && info.jsOrCsharp) rows.jsCs.push(resource.name);
  }
  io.out(
    `protected: ${rows.protected.length}   unprotected: ${rows.unprotected.length}   unsure: ${rows.unsure.length}   ` +
      `js/c# server code: ${rows.jsCs.length}   no server code: ${rows.noCode.length}\n`,
  );
  if (rows.unprotected.length > 0) io.out(`not protected (run \`torii install\`): ${rows.unprotected.join(', ')}\n`);
  if (rows.unsure.length > 0) {
    io.out(`manifest not readable with confidence (check by hand; the torii core reports the real state at start): ${rows.unsure.join(', ')}\n`);
  }
  if (rows.jsCs.length > 0) io.out(`JavaScript/C# torii cannot inspect: ${rows.jsCs.join(', ')}\n`);
  return 0;
}

function approve(dir, flags, io) {
  const lockPath = flags.lock ?? path.join(dir, 'torii', 'policy.lock.json');
  const lock = readLock(lockPath);
  const additions = Object.create(null);
  const warnings = Object.create(null);
  const warn = (name, text) => {
    warnings[name] ??= [];
    if (!warnings[name].includes(text)) warnings[name].push(text);
  };
  const declarations = Object.create(null);

  const scanned = [];
  for (const resource of findResources(dir).filter((r) => isSafeResourceName(r.name))) {
    const manifestText = fs.readFileSync(resource.manifestPath, 'utf8');
    declarations[resource.name] = parseDeclaration(manifestText);
    scanned.push({ name: resource.name, manifestText });
  }

  // 1. what manifests ask for
  for (const [name, decl] of Object.entries(declarations)) {
    if (decl.http.length === 0 && !decl.dynamic_code && !decl.follow_redirects) continue;
    // Each declared entry is read the way the runtime reads it: an entry the runtime would reject is reported and not
    // proposed, the others are proposed in canonical form and classified by their canonical host and path.
    const http = [];
    for (const entry of decl.http) {
      const parsed = normalizeEntry(entry);
      if (!parsed.ok) {
        warn(name, `declared entry ${JSON.stringify(entry.slice(0, 80))} would be ignored by torii (${parsed.reason}); not proposed`);
        continue;
      }
      http.push(parsed.entry);
      const warning = riskWarning(parsed.host, parsed.hasPath);
      if (warning) warn(name, `declared in the manifest: ${warning}`);
    }
    additions[name] = { http, dynamic_code: decl.dynamic_code, follow_redirects: decl.follow_redirects };
  }

  // 2. what the resource did in observe mode
  let notes = [];
  if (flags['from-logs']) {
    if (!fs.existsSync(flags['from-logs'])) {
      io.err(`Log file not found: ${flags['from-logs']}\n`);
      return 1;
    }
    const proposal = proposalFromEvents(readEvents(flags['from-logs']));
    notes = proposal.notes;
    for (const [name, add] of Object.entries(proposal.additions)) {
      const current = additions[name] ?? { http: [], dynamic_code: false, follow_redirects: false };
      additions[name] = {
        ...current,
        http: [...new Set([...current.http, ...add.http])],
        dynamic_code: widerDynamic(current.dynamic_code, add.dynamic_code),
      };
    }
    for (const [name, list] of Object.entries(proposal.warnings)) for (const text of list) warn(name, text);
    notes.push('log events are self-reported by each resource (a hostile one can forge its own); treat this proposal as a suggestion and review every line');
  }

  // 3. well-known libraries: always described, applied to the proposal only with --use-presets
  const presetLines = [];
  const found = matchPresets(scanned, loadPresets());
  for (const match of found.matches) {
    const applied = appliesTo(match, flags['use-presets'] === true);
    if (applied) {
      const add = (additions[match.resource] ??= { http: [], dynamic_code: false, follow_redirects: false });
      add.http = [...new Set([...add.http, ...match.preset.grants.http])];
      add.dynamic_code = widerDynamic(add.dynamic_code, match.preset.grants.dynamic_code);
    }
    presetLines.push(...describeMatch(match, applied), '');
  }
  for (const item of found.unsupported) {
    presetLines.push(`${item.resource}  (${item.entry.origin.replace('https://', '')})`, `    note       ${item.entry.note}`, '');
  }

  // 4. heuristic signals about every host about to be proposed (they order the reading, they decide nothing)
  for (const [name, add] of Object.entries(additions)) {
    for (const entry of add.http) {
      const parsed = normalizeEntry(entry);
      if (!parsed.ok) continue;
      for (const signal of hostSignals(parsed.host)) warn(name, `look closer: ${signal}`);
    }
  }

  // 5. hash of what each manifest declares today (resources unknown to the scan hash as "declares nothing")
  for (const name of Object.keys(additions)) {
    additions[name].declaration_hash = declarationHash(declarations[name] ?? { http: [] });
  }

  const next = mergeAdditions(lock, additions);
  const lines = diffLocks(lock, next);

  for (const [name, grant] of Object.entries(lock.resources)) {
    if (!additions[name] && declarations[name] && grant.declaration_hash && grant.declaration_hash !== declarationHash(declarations[name])) {
      warn(name, 'manifest declaration changed since it was approved (torii will report it at runtime); re-run approve to review');
    }
  }

  if (lines.length === 0 && Object.keys(warnings).length === 0 && notes.length === 0 && presetLines.length === 0) {
    io.out('No changes to propose.\n');
    return 0;
  }
  io.out(`Proposed changes to ${lockPath}\n\n`);
  for (const line of lines) io.out(`${line}\n`);
  for (const [name, list] of Object.entries(warnings)) {
    io.out(`\n! ${name}\n`);
    for (const text of list) io.out(`    ${text}\n`);
  }
  if (notes.length > 0) {
    io.out('\nNot proposed:\n');
    for (const note of notes) io.out(`    ${note}\n`);
  }
  if (presetLines.length > 0) {
    io.out('\nKnown libraries found:\n');
    for (const line of presetLines) io.out(`${line}\n`);
  }
  if (flags.write) {
    writeLock(lockPath, next);
    io.out(`\nWritten. Restart torii (or the resources) for the new lockfile to take effect.\n`);
  } else {
    io.out('\nNothing was written. Review the diff, then re-run with --write.\n');
  }
  return 0;
}

function loadEventsAndLock(dir, flags, io) {
  if (!flags['from-logs']) {
    io.err('Missing --from-logs <file> (the observe-mode log, torii/logs/torii.jsonl).\n');
    return null;
  }
  if (!fs.existsSync(flags['from-logs'])) {
    io.err(`Log file not found: ${flags['from-logs']}\n`);
    return null;
  }
  const lockPath = flags.lock ?? path.join(dir, 'torii', 'policy.lock.json');
  return { events: readEvents(flags['from-logs']), lock: readLock(lockPath), lockPath };
}

const show = (value) => JSON.stringify(String(value).slice(0, 160));

function simulateCommand(dir, flags, io) {
  const input = loadEventsAndLock(dir, flags, io);
  if (!input) return 1;
  const outcomes = simulate(input.events, input.lock);
  const byResource = new Map();
  for (const o of outcomes) {
    const row = byResource.get(o.resource) ?? { blocked: 0, allowed: 0, unknown: 0 };
    row[o.verdict] += o.count;
    byResource.set(o.resource, row);
  }
  io.out(`Enforce mode with ${input.lockPath}, replayed against ${input.events.length} logged events\n\n`);
  if (byResource.size === 0) {
    io.out('Nothing in the log would be blocked or allowed differently.\n');
    return 0;
  }
  io.out(`  ${'resource'.padEnd(28)} ${'blocked'.padStart(8)} ${'allowed'.padStart(8)} ${'cannot tell'.padStart(12)}\n`);
  for (const [name, row] of byResource) {
    io.out(`  ${name.slice(0, 28).padEnd(28)} ${String(row.blocked).padStart(8)} ${String(row.allowed).padStart(8)} ${String(row.unknown).padStart(12)}\n`);
  }
  const blocked = outcomes.filter((o) => o.verdict === 'blocked');
  const unknown = outcomes.filter((o) => o.verdict === 'unknown');
  if (blocked.length > 0) {
    io.out('\nWould still be blocked:\n');
    for (const o of blocked) io.out(`  ${o.resource}  ${o.type}  ${show(o.target)}  (${o.reason}, seen ${o.count}x)\n`);
  }
  if (unknown.length > 0) {
    io.out('\nCannot tell (the log keeps only the start of the path, your entry is longer):\n');
    for (const o of unknown) io.out(`  ${o.resource}  ${o.type}  ${show(o.target)}  (seen ${o.count}x)\n`);
  }
  io.out('\nRun `torii explain` on the same log for the reason behind each line and what to do about it.\n');
  return flags['fail-on-block'] && blocked.length > 0 ? 2 : 0;
}

function explainCommand(dir, flags, io) {
  const input = loadEventsAndLock(dir, flags, io);
  if (!input) return 1;
  const wanted = typeof flags.resource === 'string' ? flags.resource : null;
  const outcomes = simulate(input.events, input.lock).filter((o) => !wanted || o.resource === wanted);
  if (outcomes.length === 0) {
    io.out(wanted ? `Nothing blocked for ${wanted} in this log.\n` : 'Nothing blocked in this log.\n');
    return 0;
  }
  for (const o of outcomes) {
    const { why, fix } = explainReason(o.reason);
    const status = { blocked: 'blocked with the current lockfile', allowed: 'allowed by the current lockfile', unknown: 'cannot tell from the log (see `torii simulate`)' }[o.verdict];
    io.out(`${o.resource}  ${o.type}  ${show(o.target)}  (seen ${o.count}x)\n`);
    io.out(`  status   ${status}\n`);
    io.out(`  why      ${why}\n`);
    io.out(`  next     ${FIXES[fix] ?? FIXES.review}\n`);
    if (fix === 'grant' && o.verdict !== 'allowed') {
      if (o.type === 'http') {
        const converted = targetToEntry(o.target);
        if (converted) {
          io.out(`  lockfile "${o.resource}": { "http": [${JSON.stringify(converted.entry)}] }\n`);
          for (const text of converted.warnings) io.out(`  careful  ${text}\n`);
          const signals = hostSignals(normalizeEntry(converted.entry).host ?? '');
          for (const signal of signals) io.out(`  careful  ${signal}\n`);
        }
      } else if (o.type === 'dynamic_code') {
        const level = o.origin === 'files' ? '"files"' : 'true';
        io.out(`  lockfile "${o.resource}": { "dynamic_code": ${level} }\n`);
      }
    }
    io.out('\n');
  }
  return 0;
}

/**
 * @param {string[]} argv
 * @param {{ out: (s: string) => void, err: (s: string) => void }} io
 * @returns {number} exit code
 */
export function main(argv, rawIo = { out: (s) => process.stdout.write(s), err: (s) => process.stderr.write(s) }) {
  // Everything printed may contain text taken from logs, manifests or folder names: neutralise terminal
  // control characters (ANSI escapes, backspace, carriage return...) but keep newlines and tabs.
  const clean = (text) => String(text).replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]/g, '?');
  const io = { out: (text) => rawIo.out(clean(text)), err: (text) => rawIo.err(clean(text)) };
  const { positional, flags } = parseArgs(argv);
  const command = positional[0];
  if (!command || command === 'help' || flags.help) {
    io.out(HELP);
    return command ? 0 : 1;
  }
  if (!['install', 'uninstall', 'status', 'approve', 'simulate', 'explain'].includes(command)) {
    io.err(`Unknown command: ${command}\n\n${HELP}`);
    return 1;
  }
  const dir = resolveDir(positional, io);
  if (!dir) return 1;
  try {
    if (command === 'install') return install(dir, flags, io, false);
    if (command === 'uninstall') return install(dir, flags, io, true);
    if (command === 'status') return status(dir, io);
    if (command === 'simulate') return simulateCommand(dir, flags, io);
    if (command === 'explain') return explainCommand(dir, flags, io);
    return approve(dir, flags, io);
  } catch (error) {
    io.err(`torii: ${error.message}\n`);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
