#!/usr/bin/env node
// torii CLI: install / uninstall / status / approve. No dependencies.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { declarationHash, parseDeclaration } from './lib/declaration.mjs';
import { diffLocks, mergeAdditions, readLock, writeLock } from './lib/lock.mjs';
import { proposalFromEvents, readEvents, riskWarning } from './lib/logs.mjs';
import { isSafeResourceName } from './lib/names.mjs';
import { findResources, inspectManifest, installInto, isEscrowed, uninstallFrom } from './lib/manifest.mjs';

const HELP = `torii - runtime permission firewall for FiveM Lua resources

Usage:
  torii install   <resources-dir> [--dry-run]     add "shared_script '@torii/init.lua'" to every manifest (backup: *.torii.bak)
  torii uninstall <resources-dir> [--dry-run]     remove the line again
  torii status    <resources-dir>                 which resources are protected, which run JS/C# torii cannot inspect
  torii approve   <resources-dir> [options]       propose lockfile changes as a diff (nothing is written without --write)

approve options:
  --from-logs <file>   build the proposal from observe-mode logs (torii/logs/torii.jsonl)
  --lock <file>        lockfile to read/write (default: <resources-dir>/torii/policy.lock.json)
  --write              write the proposal to the lockfile (default: print the diff only)
`;

/** @param {string[]} argv */
function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      if (['from-logs', 'lock'].includes(key)) flags[key] = argv[(i += 1)];
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
  const counts = { done: 0, already: 0, skipped: 0 };
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
    } else {
      counts.skipped += 1;
    }
  }
  io.out(
    `${resources.length} resources found: ${counts.done} ${remove ? 'restored' : 'changed'}, ` +
      `${counts.already} already protected, ${counts.skipped} skipped (no server code)\n`,
  );
  if (!remove && counts.done > 0 && !flags['dry-run']) {
    io.out('Restart the server. torii starts in observe mode: nothing is blocked until you `set torii_mode "enforce"`.\n');
  }
  return 0;
}

function status(dir, io) {
  const resources = findResources(dir);
  const rows = { protected: [], unprotected: [], noCode: [], jsCs: [] };
  for (const resource of resources) {
    const info = inspectManifest(fs.readFileSync(resource.manifestPath, 'utf8'));
    if (!info.hasServerCode) rows.noCode.push(resource.name);
    else (info.installed ? rows.protected : rows.unprotected).push(resource.name);
    if (info.hasServerCode && info.jsOrCsharp) rows.jsCs.push(resource.name);
  }
  io.out(
    `protected: ${rows.protected.length}   unprotected: ${rows.unprotected.length}   ` +
      `js/c# server code: ${rows.jsCs.length}   no server code: ${rows.noCode.length}\n`,
  );
  if (rows.unprotected.length > 0) io.out(`not protected (run \`torii install\`): ${rows.unprotected.join(', ')}\n`);
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

  for (const resource of findResources(dir).filter((r) => isSafeResourceName(r.name))) {
    declarations[resource.name] = parseDeclaration(fs.readFileSync(resource.manifestPath, 'utf8'));
  }

  // 1. what manifests ask for
  for (const [name, decl] of Object.entries(declarations)) {
    if (decl.http.length === 0 && !decl.dynamic_code && !decl.follow_redirects) continue;
    additions[name] = { http: [...decl.http], dynamic_code: decl.dynamic_code, follow_redirects: decl.follow_redirects };
    for (const entry of decl.http) {
      const host = entry.replace(/^https?:\/\//, '').split(/[/:]/)[0].toLowerCase();
      const hasPath = /\//.test(entry.replace(/^https?:\/\//, ''));
      const warning = riskWarning(host, hasPath);
      if (warning) warn(name, `declared in the manifest: ${warning}`);
    }
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
        dynamic_code: current.dynamic_code || add.dynamic_code,
      };
    }
    for (const [name, list] of Object.entries(proposal.warnings)) for (const text of list) warn(name, text);
    notes.push('log events are self-reported by each resource (a hostile one can forge its own); treat this proposal as a suggestion and review every line');
  }

  // 3. hash of what each manifest declares today (resources unknown to the scan hash as "declares nothing")
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

  if (lines.length === 0 && Object.keys(warnings).length === 0 && notes.length === 0) {
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
  if (flags.write) {
    writeLock(lockPath, next);
    io.out(`\nWritten. Restart torii (or the resources) for the new lockfile to take effect.\n`);
  } else {
    io.out('\nNothing was written. Review the diff, then re-run with --write.\n');
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
  if (!['install', 'uninstall', 'status', 'approve'].includes(command)) {
    io.err(`Unknown command: ${command}\n\n${HELP}`);
    return 1;
  }
  const dir = resolveDir(positional, io);
  if (!dir) return 1;
  try {
    if (command === 'install') return install(dir, flags, io, false);
    if (command === 'uninstall') return install(dir, flags, io, true);
    if (command === 'status') return status(dir, io);
    return approve(dir, flags, io);
  } catch (error) {
    io.err(`torii: ${error.message}\n`);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
