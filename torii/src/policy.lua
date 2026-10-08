-- Permission model: lockfile parsing, declaration hashing and the HTTP / dynamic-code decisions.
--
-- Trust model (see docs/design.md, section 6): a resource *declares* what it wants in its manifest
-- (torii_http, torii_dynamic_code, torii_follow_redirects) but only the admin-owned lockfile
-- (torii/policy.lock.json) *grants* anything. The lockfile stores the hash of the declaration that was
-- reviewed, so a manifest that changes after approval is detected.

local req = type((...)) == 'function' and (...) or require
local url = req('url')
local sha256 = req('sha256')

local M = {}

local sub, match, lower = string.sub, string.match, string.lower
local concat, insert, sort = table.concat, table.insert, table.sort
local type, pairs, ipairs = type, pairs, ipairs

M.DECLARATION_VERSION = 'torii-decl-v1'
M.LOCK_VERSION = 1

local function trim(s)
	return (match(s, '^%s*(.-)%s*$'))
end

local function truthy(value)
	if type(value) ~= 'string' then
		return false
	end
	value = lower(trim(value))
	return value == 'yes' or value == 'true' or value == '1'
end

-- Declaration ------------------------------------------------------------------------------------------

---@class ToriiDeclaration
---@field http string[]
---@field dynamic_code boolean|'files'
---@field follow_redirects boolean

--- 'files' (load only text read from resource files), true (any text) or false.
local function dynamic_value(value)
	if type(value) == 'string' and lower(trim(value)) == 'files' then
		return 'files'
	end
	return truthy(value)
end
M.dynamic_value = dynamic_value

--- Canonical hash of a declaration. The same algorithm lives in cli/lib/declaration.mjs.
---@param decl ToriiDeclaration
---@return string
function M.declaration_hash(decl)
	local entries = {}
	for _, entry in ipairs(decl.http or {}) do
		insert(entries, trim(entry))
	end
	sort(entries)
	local lines = { M.DECLARATION_VERSION }
	for _, entry in ipairs(entries) do
		insert(lines, 'http=' .. entry)
	end
	local dynamic = decl.dynamic_code == 'files' and 'files' or (decl.dynamic_code and 'yes' or 'no')
	insert(lines, 'dynamic_code=' .. dynamic)
	insert(lines, 'follow_redirects=' .. (decl.follow_redirects and 'yes' or 'no'))
	return sha256.hex(concat(lines, '\n'))
end

--- Reads the torii_* keys of a resource manifest through the Cfx metadata natives.
---@param count_fn fun(resource: string, key: string): integer|nil GetNumResourceMetadata
---@param get_fn fun(resource: string, key: string, index: integer): string|nil GetResourceMetadata
---@param resource string
---@return ToriiDeclaration
function M.read_declaration(count_fn, get_fn, resource)
	local http = {}
	for i = 0, (count_fn(resource, 'torii_http') or 0) - 1 do
		local value = get_fn(resource, 'torii_http', i)
		if type(value) == 'string' and trim(value) ~= '' then
			insert(http, trim(value))
		end
	end
	return {
		http = http,
		dynamic_code = dynamic_value(get_fn(resource, 'torii_dynamic_code', 0)),
		follow_redirects = truthy(get_fn(resource, 'torii_follow_redirects', 0)),
	}
end

-- Allow-list entries -----------------------------------------------------------------------------------

---@class ToriiEntry
---@field scheme string
---@field host string
---@field port integer
---@field path string
---@field raw string

--- Parses "host", "host/path", "host:port/path", "http://host/..." (https is the default scheme).
---@param text string
---@return ToriiEntry|nil, string|nil
function M.parse_entry(text)
	if type(text) ~= 'string' then
		return nil, 'not_a_string'
	end
	text = trim(text)
	if text == '' then
		return nil, 'empty_entry'
	end
	local full = text
	if not match(text, '^%a[%w+.-]*://') then
		full = 'https://' .. text
	end
	local parsed, why = url.parse(full)
	if not parsed then
		return nil, why
	end
	return { scheme = parsed.scheme, host = parsed.host, port = parsed.port, path = parsed.path, raw = text }
end

--- True when `parsed` (a parsed request URL) is covered by `entry`.
--- The path rule is a prefix on a segment boundary: "/api/webhooks/123" covers "/api/webhooks/123/token"
--- but not "/api/webhooks/1234".
function M.entry_matches(entry, parsed)
	if entry.scheme ~= parsed.scheme or entry.host ~= parsed.host or entry.port ~= parsed.port then
		return false
	end
	if entry.path == '/' then
		return true
	end
	return parsed.path == entry.path or sub(parsed.path, 1, #entry.path + 1) == entry.path .. '/'
end

-- Policy object ----------------------------------------------------------------------------------------

local Policy = {}
Policy.__index = Policy

--- Builds a policy from a decoded lockfile table. Invalid entries are skipped and listed in `warnings`.
---@param lock table|nil
---@param opts table|nil { allow_private = boolean }
---@return table
function M.new(lock, opts)
	local self = setmetatable({
		resources = {},
		exempt = {},
		warnings = {},
		allow_private = opts and opts.allow_private or false,
	}, Policy)

	if type(lock) ~= 'table' then
		return self
	end
	if lock.version ~= M.LOCK_VERSION then
		insert(self.warnings, 'unsupported lockfile version')
		return self
	end
	for _, name in ipairs(type(lock.exempt) == 'table' and lock.exempt or {}) do
		if type(name) == 'string' then
			self.exempt[name] = true
		end
	end
	for name, item in pairs(type(lock.resources) == 'table' and lock.resources or {}) do
		if type(name) == 'string' and type(item) == 'table' then
			local http = {}
			for _, text in ipairs(type(item.http) == 'table' and item.http or {}) do
				local entry, why = M.parse_entry(text)
				if entry then
					insert(http, entry)
				else
					insert(self.warnings, name .. ': ignored invalid http entry (' .. tostring(why) .. ')')
				end
			end
			self.resources[name] = {
				http = http,
				dynamic_code = item.dynamic_code == true or (item.dynamic_code == 'files' and 'files') or false,
				follow_redirects = item.follow_redirects == true,
				declaration_hash = type(item.declaration_hash) == 'string' and item.declaration_hash or nil,
			}
		end
	end
	return self
end

---@param name string
function Policy:grants(name)
	return self.resources[name]
end

---@param name string
function Policy:is_exempt(name)
	return self.exempt[name] == true
end

--- A host is a poor allow-list entry when anybody can host content there (a path prefix does not help)
--- or, for shared APIs such as Discord, when no path prefix narrows it down to one account.
local function risk_of(entry, host)
	local risk = url.host_risk(host)
	if risk == 'user_content' or (risk == 'shared_api' and entry.path == '/') then
		return risk
	end
	return nil
end

local function describe(parsed)
	local default_port = parsed.scheme == 'https' and 443 or 80
	local host = parsed.kind == 'ipv6' and '[' .. parsed.host .. ']' or parsed.host
	local port = parsed.port ~= default_port and ':' .. parsed.port or ''
	return parsed.scheme .. '://' .. host .. port .. url.redact_path(parsed.path)
end

---@class ToriiHttpDecision
---@field allow boolean
---@field reason string
---@field target string log-safe description (never contains the query string or long path secrets)
---@field host string|nil
---@field risk string|nil 'user_content'|'shared_api' when the matched host is a poor allow-list entry

--- Decides whether `resource` may request `raw_url`.
---@param resource string
---@param raw_url any
---@return ToriiHttpDecision
function Policy:check_http(resource, raw_url)
	local parsed, why = url.parse(raw_url)
	if not parsed then
		return { allow = false, reason = 'invalid_url:' .. tostring(why), target = '<unparseable url>' }
	end
	local target = describe(parsed)
	local blocked = url.classify_host(parsed)
	if blocked and not self.allow_private then
		return { allow = false, reason = blocked, target = target, host = parsed.host }
	end
	local grants = self.resources[resource]
	if not grants then
		return { allow = false, reason = 'resource_not_in_lockfile', target = target, host = parsed.host }
	end
	for _, entry in ipairs(grants.http) do
		if M.entry_matches(entry, parsed) then
			return {
				allow = true,
				reason = 'allowed',
				target = target,
				host = parsed.host,
				risk = risk_of(entry, parsed.host),
			}
		end
	end
	return { allow = false, reason = 'not_in_allow_list', target = target, host = parsed.host }
end

--- Dynamic code (`load` with text) permission.
--- `from_files` tells whether the text is exactly what the resource read from resource files (see guard.lua).
---@param resource string
---@param from_files boolean|nil
---@return boolean allow, string reason
function Policy:check_dynamic_code(resource, from_files)
	local grants = self.resources[resource]
	if not grants then
		return false, 'resource_not_in_lockfile'
	end
	if grants.dynamic_code == true then
		return true, 'allowed'
	end
	if grants.dynamic_code == 'files' then
		if from_files then
			return true, 'allowed'
		end
		return false, 'text_not_from_resource_files'
	end
	return false, 'dynamic_code_not_granted'
end

--- Whether redirects may be followed for `resource` (default: no).
function Policy:follow_redirects(resource)
	local grants = self.resources[resource]
	return grants ~= nil and grants.follow_redirects == true
end

return M
