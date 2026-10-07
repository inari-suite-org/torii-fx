// Declaration hashing and manifest key parsing. The hash algorithm MUST stay identical to
// torii/src/policy.lua (declaration_hash); test/declaration.test.mjs checks a shared test vector.

import { createHash } from 'node:crypto';
import { lex } from './lua-lite.mjs';

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

/** Removes Lua comments and long strings, keeping quoted strings (see lua-lite.mjs). */
export function stripLuaComments(text) {
  return lex(text).code;
}

/**
 * Quoted strings found in a directive such as `torii_http { 'a', 'b' }`, `torii_http 'a'` or `torii_http('a')`.
 * With `skeleton` (from lex), a directive word that sits inside a string or a comment is not a directive.
 */
export function directiveValues(text, directive, skeleton = text) {
  const values = [];
  const pattern = new RegExp(String.raw`(?:^|[^\w])${directive}\s*(?:\(\s*)?(?:\{([^}]*)\}|(['"])(.*?)\2)`, 'g');
  for (const match of text.matchAll(pattern)) {
    const at = match.index + match[0].indexOf(directive);
    if (skeleton.slice(at, at + directive.length) !== directive) continue;
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
  const { code: text, skeleton } = lex(manifestText);
  return {
    http: directiveValues(text, 'torii_http', skeleton)
      .map((entry) => entry.trim())
      .filter(Boolean),
    dynamic_code: truthy(directiveValues(text, 'torii_dynamic_code', skeleton)[0]),
    follow_redirects: truthy(directiveValues(text, 'torii_follow_redirects', skeleton)[0]),
  };
}
