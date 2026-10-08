// Heuristic signals about a host name, shown next to a proposed grant. They help a human read the diff in the right
// order; they never decide anything. Every signal has a false-positive rate, and an ordinary looking host can still
// be hostile.

/** Domains people expect in FiveM resources, used to spot look-alikes. */
export const KNOWN_DOMAINS = [
  'github.com', 'githubusercontent.com', 'discord.com', 'discordapp.com', 'discord.gg', 'cfx.re', 'fivem.net',
  'tebex.io', 'google.com', 'googleapis.com', 'cloudflare.com', 'pastebin.com', 'youtube.com', 'twitch.tv',
  'steamcommunity.com', 'steampowered.com', 'microsoft.com', 'amazonaws.com', 'paypal.com', 'imgur.com',
];

/** Optimal string alignment distance (Damerau-Levenshtein with adjacent transpositions). */
export function editDistance(a, b) {
  const rows = a.length + 1;
  const cols = b.length + 1;
  const d = Array.from({ length: rows }, (_, i) => Array.from({ length: cols }, (_, j) => (i === 0 ? j : j === 0 ? i : 0)));
  for (let i = 1; i < rows; i += 1) {
    for (let j = 1; j < cols; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
    }
  }
  return d[a.length][b.length];
}

/** Shannon entropy of a string, in bits per character. */
export function entropy(text) {
  if (text.length === 0) return 0;
  const counts = new Map();
  for (const ch of text) counts.set(ch, (counts.get(ch) ?? 0) + 1);
  let h = 0;
  for (const n of counts.values()) {
    const p = n / text.length;
    h -= p * Math.log2(p);
  }
  return h;
}

const isIp = (host) => /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':');

/**
 * @param {string} rawHost a host as torii normalises it (lower case, no trailing dot, no brackets)
 * @returns {string[]} human-readable signals, empty when nothing stands out
 */
export function hostSignals(rawHost) {
  const host = String(rawHost ?? '').toLowerCase().replace(/\.$/, '');
  if (!host) return [];
  const signals = [];
  if (isIp(host)) {
    signals.push(`${host} is a raw IP address: public APIs almost always use a name, loaders often do not`);
    return signals;
  }
  const labels = host.split('.');
  const registrable = labels.slice(-2).join('.');
  const known = KNOWN_DOMAINS.find((d) => host === d || host.endsWith(`.${d}`));

  if (labels.some((label) => label.startsWith('xn--'))) {
    signals.push(`${host} uses an internationalised (punycode) label, which can imitate another name with look-alike letters`);
  }
  if (!known) {
    for (const domain of KNOWN_DOMAINS) {
      if (host.includes(`${domain}.`)) {
        signals.push(`${host} contains "${domain}" but belongs to ${registrable}`);
        break;
      }
      const distance = editDistance(registrable, domain);
      if (distance > 0 && distance <= 2 && domain.length >= 6) {
        signals.push(`${registrable} looks like ${domain} (${distance} character${distance > 1 ? 's' : ''} apart)`);
        break;
      }
    }
  }
  for (const label of labels.slice(0, -1)) {
    const digits = (label.match(/\d/g) ?? []).length / label.length;
    if (label.length >= 30) {
      signals.push(`the label "${label.slice(0, 40)}" is unusually long`);
    } else if ((label.length >= 12 && entropy(label) >= 3.6) || (label.length >= 8 && digits >= 0.4)) {
      signals.push(`the label "${label}" looks randomly generated`);
    }
  }
  return signals;
}
