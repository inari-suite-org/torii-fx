// Normalising allow-list entries ("host", "host:port/path", "http://host/...") for the CLI.
//
// The runtime parser (torii/src/url.lua, policy.parse_entry) is the authority. The CLI only needs to classify an
// entry for warnings, so it must classify the SAME host the runtime would see: any entry the runtime would reject is
// reported as invalid, and the rest are reduced to a canonical form (lower-case host, no trailing dot, default port
// dropped, dot segments resolved) before looking at the host or the path.

/**
 * @param {unknown} text
 * @returns {{ ok: true, entry: string, host: string, hasPath: boolean } | { ok: false, reason: string }}
 */
export function normalizeEntry(text) {
  if (typeof text !== 'string') return { ok: false, reason: 'not a string' };
  const raw = text.trim();
  if (raw === '') return { ok: false, reason: 'empty' };
  if (/[\s\\*]/.test(raw)) return { ok: false, reason: 'whitespace, backslash or wildcard' };
  if (/[^\x21-\x7e]/.test(raw)) return { ok: false, reason: 'non-ASCII character' };
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : `https://${raw}`;
  const afterScheme = withScheme.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
  const authority = afterScheme.split(/[/?#]/)[0];
  if (authority.includes('@')) return { ok: false, reason: 'user info is not allowed' };
  if (authority.includes('%')) return { ok: false, reason: 'percent-encoding in the host' };

  let url;
  try {
    url = new URL(withScheme);
  } catch {
    return { ok: false, reason: 'not a valid URL' };
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return { ok: false, reason: 'only http and https' };

  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  if (host === '') return { ok: false, reason: 'empty host' };
  const pathname = url.pathname.replace(/\/+$/, '') || '/';
  const hasPath = pathname !== '/';
  const defaultPort = url.protocol === 'https:' ? '443' : '80';
  const port = url.port && url.port !== defaultPort ? `:${url.port}` : '';
  const scheme = url.protocol === 'http:' ? 'http://' : '';
  return { ok: true, entry: `${scheme}${host}${port}${hasPath ? pathname : ''}`, host: host.replace(/^\[|\]$/g, ''), hasPath };
}
