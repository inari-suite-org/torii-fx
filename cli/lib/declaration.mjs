// Declaration hashing and manifest key parsing. The hash algorithm MUST stay identical to
// torii/src/policy.lua (declaration_hash); test/declaration.test.mjs checks a shared test vector.

import { createHash } from 'node:crypto';

export const DECLARATION_VERSION = 'torii-decl-v1';

/** @typedef {{ http: string[], dynamic_code: boolean, follow_redirects: boolean }} Declaration */

/** @param {Partial<Declaration>} decl */
export function declarationHash(decl) {
  const entries = (decl.http ?? []).map((entry) => entry.trim()).sort();
  const lines = [
    DECLARATION_VERSION,
    ...entries.map((entry) => `http=${entry}`),
    `dynamic_code=${decl.dynamic_code ? 'yes' : 'no'}`,
    `follow_redirects=${decl.follow_redirects ? 'yes' : 'no'}`,
  ];
  return createHash('sha256').update(lines.join('\n')).digest('hex');
}

/** Removes Lua comments (good enough for manifests; does not understand comment markers inside strings). */
export function stripLuaComments(text) {
  return text.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '').replace(/--.*$/gm, '');
}

/** Quoted strings found in a directive such as `torii_http { 'a', 'b' }`, `torii_http 'a'` or `torii_http('a')`. */
export function directiveValues(text, directive) {
  const values = [];
  const pattern = new RegExp(`(?:^|[^\\w])${directive}\\s*(?:\\(\\s*)?(?:\\{([^}]*)\\}|(['"])(.*?)\\2)`, 'g');
  for (const match of text.matchAll(pattern)) {
    if (match[1] !== undefined) {
      for (const item of match[1].matchAll(/(['"])(.*?)\1/g)) values.push(item[2]);
    } else {
      values.push(match[3]);
    }
  }
  return values;
}

const truthy = (value) => ['yes', 'true', '1'].includes(String(value ?? '').trim().toLowerCase());

/**
 * Reads the torii_* declaration of a manifest. This is an approximation of what GetResourceMetadata
 * returns at runtime; the runtime value is what torii compares with the lockfile hash.
 * @returns {Declaration}
 */
export function parseDeclaration(manifestText) {
  const text = stripLuaComments(manifestText);
  return {
    http: directiveValues(text, 'torii_http')
      .map((entry) => entry.trim())
      .filter(Boolean),
    dynamic_code: truthy(directiveValues(text, 'torii_dynamic_code')[0]),
    follow_redirects: truthy(directiveValues(text, 'torii_follow_redirects')[0]),
  };
}
