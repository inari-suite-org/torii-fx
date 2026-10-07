// Finding resources, reading manifests, adding / removing the torii include line.

import fs from 'node:fs';
import path from 'node:path';
import { directiveValues } from './declaration.mjs';
import { lex, readsUncertainly } from './lua-lite.mjs';

export const INSTALL_LINE = "shared_script '@torii/init.lua'";
const INSTALL_PATTERN = /shared_script\s*\(?\s*(['"])@torii\/init\.lua\1\s*\)?/;
const MANIFEST_NAMES = ['fxmanifest.lua', '__resource.lua'];
const MAX_DEPTH = 3;
const IGNORED_DIRS = new Set(['node_modules', '.git', 'torii']);

/** @typedef {{ name: string, dir: string, manifestPath: string }} ResourceRef */

/**
 * Finds resources below `root`: folders containing a manifest, searched through `[category]` folders.
 * A folder that has a manifest is a resource; we do not look inside it.
 * @returns {ResourceRef[]}
 */
export function findResources(root) {
  /** @type {ResourceRef[]} */
  const found = [];
  const walk = (dir, depth) => {
    if (depth > MAX_DEPTH) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    const manifest = MANIFEST_NAMES.find((name) => entries.some((e) => e.isFile() && e.name === name));
    if (manifest && depth > 0) {
      found.push({ name: path.basename(dir), dir, manifestPath: path.join(dir, manifest) });
      return;
    }
    for (const entry of entries) {
      if (entry.isDirectory() && !IGNORED_DIRS.has(entry.name)) walk(path.join(dir, entry.name), depth + 1);
    }
  };
  walk(root, 0);
  return found.sort((a, b) => a.name.localeCompare(b.name));
}

/** True when the first shared_script directive of the (comment-free) manifest is the torii include. */
function firstSharedIsTorii(code, skeleton) {
  const at = skeleton.search(/\bshared_scripts?\b/);
  if (at === -1) return false;
  const rest = code.slice(at).replace(/^shared_scripts?\s*\(?\s*\{?\s*/, '');
  return /^['"]@torii\/init\.lua['"]/.test(rest);
}

/**
 * Describes the server code a manifest declares.
 * @param {string} manifestText
 */
export function inspectManifest(manifestText) {
  const { code: text, skeleton, longStrings, unterminated } = lex(manifestText);
  const scripts = ['shared_script', 'shared_scripts', 'server_script', 'server_scripts']
    .flatMap((directive) => directiveValues(text, directive, skeleton))
    .filter((entry) => !entry.startsWith('@'));
  const extension = (entry) => /\.([a-z0-9]+)['"]?$/i.exec(entry)?.[1]?.toLowerCase();
  const js = scripts.filter((entry) => ['js', 'ts'].includes(extension(entry))).length;
  const csharp = scripts.filter((entry) => ['dll', 'cs'].includes(extension(entry))).length;
  return {
    hasServerCode: scripts.length > 0,
    // FXServer's core checks that the FIRST shared script is the torii include, so this does too
    installed: firstSharedIsTorii(text, skeleton),
    presentButNotFirst: !firstSharedIsTorii(text, skeleton) && INSTALL_PATTERN.test(text),
    uncertain: readsUncertainly(skeleton, longStrings + unterminated),
    jsOrCsharp: js + csharp > 0,
    jsCount: js,
    csharpCount: csharp,
  };
}

/** True when the resource folder contains Cfx Asset Escrow files (*.fxap). */
export function isEscrowed(dir) {
  try {
    return fs.readdirSync(dir).some((name) => name.toLowerCase().endsWith('.fxap'));
  } catch {
    return false;
  }
}

/**
 * Returns the manifest text with the torii line inserted right after fx_version (or
 * resource_manifest_version), or at the top when neither is found. Keeps the file's line endings.
 */
export function addInstallLine(text) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((line) => /^\s*(fx_version|resource_manifest_version)\b/.test(line));
  lines.splice(at === -1 ? 0 : at + 1, 0, INSTALL_LINE);
  return lines.join(eol);
}

/** Removes the first torii include line. Returns the new text (unchanged if the line is absent). */
export function removeInstallLine(text) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((line) => INSTALL_PATTERN.test(line) && line.trim() === INSTALL_LINE);
  if (at === -1) return text;
  lines.splice(at, 1);
  return lines.join(eol);
}

/** True for an existing plain file (a symlink is not one). */
function isRegularFile(file) {
  try {
    return fs.lstatSync(file).isFile();
  } catch {
    return false;
  }
}

/** Refuses to write through symlinks: a hostile resource folder must not redirect our writes elsewhere. */
function assertRegularFile(file) {
  if (!isRegularFile(file)) throw new Error(`refusing to touch ${file}: not a regular file (symlink?)`);
}

export const backupPath = (manifestPath) => `${manifestPath}.torii.bak`;

/**
 * Installs the include line. Writes a one-time backup next to the manifest.
 * Refuses manifests it cannot read with confidence, and refuses to write a result in which the include would not be
 * the first shared script (the torii core would flag it at start anyway).
 * @returns {'installed'|'already'|'no-server-code'|'uncertain'|'not-first'}
 */
export function installInto(resource, { dryRun = false } = {}) {
  const text = fs.readFileSync(resource.manifestPath, 'utf8');
  const info = inspectManifest(text);
  if (info.installed) return 'already';
  if (info.uncertain) return 'uncertain';
  if (!info.hasServerCode) return 'no-server-code';
  const next = addInstallLine(text);
  if (!inspectManifest(next).installed) return 'not-first';
  if (!dryRun) {
    assertRegularFile(resource.manifestPath);
    // 'wx' = exclusive create: fails if the path exists, including as a symlink, and never follows one.
    try {
      fs.writeFileSync(backupPath(resource.manifestPath), text, { flag: 'wx' });
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      assertRegularFile(backupPath(resource.manifestPath)); // an existing backup must be a plain file
    }
    fs.writeFileSync(resource.manifestPath, next);
  }
  return 'installed';
}

/** @returns {'removed'|'absent'} */
export function uninstallFrom(resource, { dryRun = false } = {}) {
  const text = fs.readFileSync(resource.manifestPath, 'utf8');
  const next = removeInstallLine(text);
  if (next === text) return 'absent';
  if (!dryRun) {
    assertRegularFile(resource.manifestPath);
    fs.writeFileSync(resource.manifestPath, next);
    const backup = backupPath(resource.manifestPath);
    if (isRegularFile(backup) && fs.readFileSync(backup, 'utf8') === next) fs.unlinkSync(backup);
  }
  return 'removed';
}
