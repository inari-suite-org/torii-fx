// The three levels of the dynamic_code permission, as torii/src/policy.lua reads them:
//   false    load() on text is refused
//   'files'  load() is allowed only on text exactly as LoadResourceFile returned it (module loaders such as ox_lib)
//   true     load() is allowed on any text

/** @typedef {false | 'files' | true} DynamicLevel */

const RANK = new Map([
  [false, 0],
  ['files', 1],
  [true, 2],
]);

/** Manifest value (`torii_dynamic_code 'files'`, `'yes'`, ...) to a level. */
export function manifestDynamic(value) {
  const text = String(value ?? '').trim().toLowerCase();
  if (text === 'files') return 'files';
  return ['yes', 'true', '1'].includes(text);
}

/** Lockfile JSON value to a level; anything unexpected is no permission. */
export function lockDynamic(value) {
  if (value === true) return true;
  if (value === 'files') return 'files';
  return false;
}

/** The broader of two levels (merging never narrows an existing grant). */
export function widerDynamic(a, b) {
  return (RANK.get(lockDynamic(b)) ?? 0) > (RANK.get(lockDynamic(a)) ?? 0) ? lockDynamic(b) : lockDynamic(a);
}

/** Whether a level allows a load() whose text came from `origin` ('files' or 'memory', as logged by the guard). */
export function dynamicAllows(level, origin) {
  return level === true || (level === 'files' && origin === 'files');
}

/** How the level is written in a declaration hash line (must match policy.lua). */
export function dynamicHashValue(level) {
  if (level === 'files') return 'files';
  return level ? 'yes' : 'no';
}
