// Known-library presets: what a well-known resource legitimately needs, checked against its source.
//
// A preset is a suggestion tied to a resource FOLDER NAME. A hostile resource can be named "ox_lib", so a preset
// never applies silently: it is printed with its evidence, and only applied with --use-presets, and then only
// when the manifest also carries the origin hint the preset expects. A preset without a hint is never applied.
// The hint is a partial guard only: a manifest can be copied, so the admin still has to check the source.

import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const PRESET_FILE = fileURLToPath(new URL('../presets/known-resources.json', import.meta.url));

/** @typedef {{ dynamic_code: import('./dynamic.mjs').DynamicLevel, http: string[] }} PresetGrants */
/** @typedef {{ id: string, resources: string[], origin: string, originHint: string|null, checked: object, grants: PresetGrants, why: string[], youProvide: string[], alsoSeen: string[] }} Preset */

export function loadPresets(file = PRESET_FILE) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (raw.version !== 1) throw new Error(`${file}: unsupported preset file version ${raw.version}`);
  return { presets: raw.presets ?? [], unsupportedRuntime: raw.unsupportedRuntime ?? [] };
}

/**
 * Looks for presets matching resource folder names.
 * @param {{ name: string, manifestText: string }[]} resources
 * @param {{ presets: Preset[], unsupportedRuntime: object[] }} catalog
 */
export function matchPresets(resources, catalog) {
  const matches = [];
  const unsupported = [];
  for (const resource of resources) {
    const preset = catalog.presets.find((p) => p.resources.includes(resource.name));
    if (preset) {
      const hint = preset.originHint?.toLowerCase() ?? null;
      const originOk = hint === null ? null : resource.manifestText.toLowerCase().includes(hint);
      matches.push({ resource: resource.name, preset, originOk });
      continue;
    }
    const other = catalog.unsupportedRuntime.find((p) => p.resources.includes(resource.name));
    if (other) unsupported.push({ resource: resource.name, entry: other });
  }
  return { matches, unsupported };
}

/** A preset is applied only when asked for AND the manifest carries the origin hint the preset expects. */
export function appliesTo(match, usePresets) {
  return usePresets && match.originOk === true;
}

/** Text block shown by `torii approve` for one match. */
export function describeMatch(match, applied) {
  const { preset } = match;
  const lines = [
    `${match.resource}  (matches ${preset.origin.replace('https://', '')}, checked at ${preset.checked.commit} on ${preset.checked.date})`,
  ];
  const grants = [];
  if (preset.grants.dynamic_code) grants.push(preset.grants.dynamic_code === 'files' ? "dynamic_code 'files'" : 'dynamic_code');
  for (const entry of preset.grants.http) grants.push(`http ${entry}`);
  lines.push(grants.length > 0 ? `    suggests   ${grants.join(', ')}` : '    suggests   no permission at all');
  for (const reason of preset.why) lines.push(`    why        ${reason}`);
  for (const item of preset.youProvide) lines.push(`    you add    ${item}`);
  for (const item of preset.alsoSeen) lines.push(`    also seen  ${item}`);
  if (match.originOk === false) {
    lines.push(`    origin     the manifest does not mention what this preset expects, so it is NOT applied`);
  } else if (match.originOk === true) {
    lines.push(`    origin     the manifest names the expected author or repository (a manifest can be copied: still check the source)`);
  } else {
    lines.push(`    origin     this preset has no origin hint, so it is NOT applied: check that the folder really is ${preset.origin}`);
  }
  lines.push(applied ? '    result     applied to the proposal' : '    result     not applied (add --use-presets to include it in the proposal)');
  return lines;
}
