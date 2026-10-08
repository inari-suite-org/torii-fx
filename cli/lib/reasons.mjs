// Plain-language explanations of the reasons torii logs, and what an admin can do about each.
// Used by `torii explain`. A reason that is not listed falls back to a generic text.

const ADDRESS = 'torii refuses this destination whatever the lockfile says. Local and private addresses are where a backdoor reaches the server itself, txAdmin, a database or a cloud metadata service.';

export const REASONS = {
  resource_not_in_lockfile: {
    why: 'This resource has no entry in the lockfile, so it has no permission at all.',
    fix: 'grant',
  },
  not_in_allow_list: {
    why: 'The resource has an entry in the lockfile, but this host or path is not in its "http" list.',
    fix: 'grant',
  },
  dynamic_code_not_granted: {
    why: 'The resource tried to run text as Lua with load(). Many libraries do this for their own files; a remote-code loader does it with downloaded text.',
    fix: 'grant',
  },
  text_not_from_resource_files: {
    why: 'The resource may only run text exactly as it read it from resource files (dynamic_code "files"), and this text was built or changed in memory, downloaded, or written by the resource itself.',
    fix: 'grant',
  },
  loopback_address: { why: `The request targets the machine itself. ${ADDRESS}`, fix: 'never' },
  private_address: { why: `The request targets a private network range. ${ADDRESS}`, fix: 'never' },
  link_local_address: { why: `The request targets a link-local address such as the cloud metadata service. ${ADDRESS}`, fix: 'never' },
  local_name: { why: `The request targets a local name (localhost, *.local, *.internal, *.users.cfx.re). ${ADDRESS}`, fix: 'never' },
  single_label_host: { why: `The request targets a single-label name, which resolves on the local network. ${ADDRESS}`, fix: 'never' },
  unspecified_address: { why: `The request targets 0.0.0.0 or ::. ${ADDRESS}`, fix: 'never' },
  shared_address_space: { why: `The request targets carrier-grade NAT space (100.64.0.0/10). ${ADDRESS}`, fix: 'never' },
  reserved_address: { why: `The request targets a reserved or documentation range. ${ADDRESS}`, fix: 'never' },
  multicast_or_reserved_address: { why: `The request targets a multicast or reserved range. ${ADDRESS}`, fix: 'never' },
  binary_chunk_refused: {
    why: 'The resource tried to load Lua bytecode. Crafted bytecode can corrupt the Lua VM and escape any in-VM protection, so torii refuses it in every mode. Legitimate resources ship source code.',
    fix: 'never',
  },
  manifest_write: {
    why: 'The resource tried to rewrite a manifest (fxmanifest.lua or __resource.lua). Removing the torii line this way is how a resource would switch protection off.',
    fix: 'never',
  },
  missing_torii_init_line: {
    why: 'The resource has server code but its manifest does not start with the torii include, so nothing inside it is protected.',
    fix: 'install',
  },
  unsupported_runtime_js_or_csharp: {
    why: 'The resource runs JavaScript or C# on the server. torii only inspects Lua, so it cannot see what that code does.',
    fix: 'exempt',
  },
  declaration_changed_since_approval: {
    why: 'The permissions the manifest asks for changed after you approved them (often after an update of the resource).',
    fix: 'review',
  },
  declaration_not_approved: {
    why: 'The manifest asks for permissions that are not in the lockfile yet.',
    fix: 'review',
  },
  protected_resource_never_reported: {
    why: 'The manifest includes torii, but the resource never reported that protection was installed. The include may have failed to load.',
    fix: 'check',
  },
  sensitive_name: {
    why: 'The resource read a convar whose name looks secret (password, token, connection string). This is only logged.',
    fix: 'info',
  },
  internal_error: {
    why: 'torii could not evaluate the request. In enforce mode it fails closed (blocks); in observe mode it lets the request through.',
    fix: 'report',
  },
};

export const FIXES = {
  grant: 'Add it to the lockfile if, and only if, you know why this resource needs it.',
  never: 'This cannot be allowed. If a resource genuinely needs it, that resource is doing something torii is designed to stop.',
  install: 'Run `torii install` on your resources folder, or add `shared_script \'@torii/init.lua\'` as the first script line.',
  exempt: 'Decide knowingly: check where the resource comes from, then list it under "exempt" in the lockfile, or remove it.',
  review: 'Run `torii approve` to see the new request as a diff before deciding.',
  check: 'Check that the torii folder is named "torii", is started first, and that the server console shows no "Failed to load script @torii/init.lua".',
  info: 'Nothing to do unless the resource has no reason to read it.',
  report: 'Please report it with the log line (it contains no secret) so we can add a test.',
};

export function explainReason(reason) {
  const key = String(reason ?? '').startsWith('invalid_url') ? 'invalid_url' : reason;
  if (key === 'invalid_url') {
    return {
      why: `The URL is malformed or ambiguous (${String(reason).slice('invalid_url:'.length) || 'unknown'}). torii refuses anything a web client could read differently from torii itself.`,
      fix: 'never',
    };
  }
  return REASONS[key] ?? { why: `Reason "${reason}".`, fix: 'review' };
}
