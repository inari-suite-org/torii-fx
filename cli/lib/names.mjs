/**
 * Resource names become object keys. Accept plain identifiers only, and reject every name that already
 * exists on Object.prototype (__proto__, constructor, toString, ...): no denylist to keep up to date.
 */
export function isSafeResourceName(name) {
  return typeof name === 'string' && /^[\w.\-[\]]{1,100}$/.test(name) && !(name in Object.prototype);
}
