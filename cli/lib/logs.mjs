// Turns observe-mode logs (torii.jsonl) into proposed grants. Nothing here is trusted blindly: the
// proposal is only ever printed as a diff for the admin to review (see `torii approve`).

import fs from 'node:fs';

/** Reasons that mean "torii refuses this whatever the lockfile says": never propose them. */
const NEVER_PROPOSE = /^(invalid_url:|loopback_address|private_address|link_local_address|local_name|single_label_host|unspecified_address|shared_address_space|reserved_address|multicast_or_reserved_address)/;

const USER_CONTENT = [
  'pastebin.com', 'githubusercontent.com', 'github.io', 'gitlab.io', 'hastebin.com', 'paste.ee', 'ghostbin.com',
  'transfer.sh', 'ngrok.io', 'ngrok-free.app', 'trycloudflare.com', 'workers.dev', 'pages.dev', 'herokuapp.com',
  'vercel.app', 'netlify.app', 'glitch.me', 'repl.co', 'replit.dev', 'firebaseapp.com', 'web.app', 'onrender.com',
  'fly.dev', '000webhostapp.com', 'bit.ly', 'tinyurl.com', 'is.gd', 'cdn.discordapp.com', 'media.discordapp.net',
  'dropboxusercontent.com', 'drive.google.com', 'docs.google.com', 'sites.google.com', 'blogspot.com', 'wordpress.com',
];
const SHARED_API = new Set([
  'discord.com', 'ptb.discord.com', 'canary.discord.com', 'discordapp.com', 'api.telegram.org', 'hooks.slack.com',
  'api.github.com', 'api.pastes.dev',
]);

/** @returns {'user_content'|'shared_api'|null} */
export function hostRisk(host) {
  if (SHARED_API.has(host)) return 'shared_api';
  if (USER_CONTENT.some((suffix) => host === suffix || host.endsWith(`.${suffix}`))) return 'user_content';
  return null;
}

/** Parses a JSON-lines file, ignoring blank and corrupt lines. */
export function readEvents(file) {
  const events = [];
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      /* a half-written last line is normal in a live log */
    }
  }
  return events;
}

/**
 * Converts a logged target ("https://host:8443/api/v1") into an allow-list entry ("host:8443/api/v1").
 * Returns null when the target cannot become an entry.
 * @returns {{ entry: string, warnings: string[] } | null}
 */
export function targetToEntry(target) {
  const match = /^(https?):\/\/(\[[^\]]+\]|[^/:]+)(:\d+)?(\/.*)?$/.exec(target ?? '');
  if (!match) return null;
  const [, scheme, host, port = '', pathPart = '/'] = match;
  const warnings = [];
  let pathText = pathPart;
  const redacted = pathText.split('/').findIndex((segment) => segment === '<redacted>');
  if (redacted !== -1) {
    pathText = `${pathText.split('/').slice(0, redacted).join('/') || '/'}`;
    warnings.push(`a token-like path segment was removed from ${host}; check the prefix is specific enough`);
  }
  const risk = hostRisk(host.toLowerCase());
  if (risk === 'user_content' || (risk === 'shared_api' && pathText === '/')) {
    warnings.push(
      risk === 'shared_api'
        ? `${host} accepts data from anyone with an account: restrict it with a path prefix (e.g. /api/webhooks/<id>)`
        : `${host} serves or receives user content: anybody can host a payload there, a path prefix does not make it safe; drop it if you can`,
    );
  }
  const prefix = scheme === 'http' ? 'http://' : '';
  return { entry: `${prefix}${host}${port}${pathText === '/' ? '' : pathText.replace(/\/$/, '')}`, warnings };
}

/**
 * Builds proposed grants from observe-mode events.
 * @param {object[]} events
 * @returns {{ additions: Record<string, { http: string[], dynamic_code: boolean }>, notes: string[] , warnings: Record<string, string[]> }}
 */
export function proposalFromEvents(events) {
  const additions = {};
  const warnings = {};
  const notes = [];
  const get = (name) => (additions[name] ??= { http: [], dynamic_code: false });
  const warn = (name, text) => ((warnings[name] ??= []).includes(text) ? 0 : warnings[name].push(text));

  for (const event of events) {
    const resource = event.resource;
    if (typeof resource !== 'string' || resource === 'torii') continue;
    if (event.type === 'http' && (event.decision === 'would_deny' || event.decision === 'deny')) {
      if (NEVER_PROPOSE.test(event.reason ?? '')) {
        notes.push(`${resource}: ${event.target} is always refused (${event.reason}), not proposed`);
        continue;
      }
      const converted = targetToEntry(event.target);
      if (!converted) continue;
      const grant = get(resource);
      if (!grant.http.includes(converted.entry)) grant.http.push(converted.entry);
      for (const text of converted.warnings) warn(resource, text);
    } else if (event.type === 'dynamic_code' && (event.decision === 'would_deny' || event.decision === 'deny')) {
      get(resource).dynamic_code = true;
      warn(resource, 'dynamic_code lets this resource run any text as Lua (many libraries need it; a backdoor does too)');
    } else if (event.type === 'bytecode') {
      notes.push(`${resource}: tried to load a binary chunk (never allowed, never proposed)`);
    }
  }
  return { additions, warnings, notes: [...new Set(notes)] };
}
