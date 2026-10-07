-- Installs torii's interception layer inside ONE resource's Lua state.
--
-- Everything environment-specific (globals table, policy, reporting, original functions) is passed in
-- through `env`, so the module is testable with fake natives (see spec/).
--
-- Rules every wrapper follows:
--   * Never raise an error because of torii's own logic. Reporting goes through pcall.
--   * enforce: HTTP denials look like a network failure (the native returns -1, which makes
--     PerformHttpRequest call back with status 0). `load` denials return nil + message, like a syntax error.
--   * observe: nothing is blocked; the decision that *would* have been taken is logged.
--   * Never log secrets: no request bodies, no headers, no query strings, convar *names* only.

local M = {}

local type, pcall, select, tostring, tonumber, next, rawget, rawset, ipairs =
	type, pcall, select, tostring, tonumber, next, rawget, rawset, ipairs
local sub, lower, match, gsub, byte, find =
	string.sub, string.lower, string.match, string.gsub, string.byte, string.find
local math_type, tointeger = math.type, math.tointeger

-- Native invocation hashes: GetHashKey of the UPPER_SNAKE native name (verified on artifact 36897,
-- see docs/experiments-results.md).
M.HASHES = {
	[0x6b171e87] = 'PerformHttpRequestInternalEx',
	[0x8e8cc653] = 'PerformHttpRequestInternal',
	[0x561c060b] = 'ExecuteCommand',
	[0x6ccd2564] = 'GetConvar',
	[0xf5c6330c] = 'SetHttpHandler',
	[0xa09e7e7b] = 'SaveResourceFile',
}

M.WRAPPED_NAMES = {
	PerformHttpRequestInternalEx = true,
	PerformHttpRequestInternal = true,
	ExecuteCommand = true,
	GetConvar = true,
	SetHttpHandler = true,
	SaveResourceFile = true,
}

local SELF_SOURCE = debug.getinfo(1, 'S').source

local DEDUP_WINDOW_MS = 30000
local DEDUP_MAX_KEYS = 512

local SENSITIVE_CONVAR_PARTS = {
	'password',
	'secret',
	'token',
	'licensekey',
	'license_key',
	'connection_string',
	'api_key',
	'apikey',
	'webhook',
	'rcon',
	'webapikey',
	'mysql',
}

---@param name any
---@return boolean
function M.is_sensitive_convar(name)
	if type(name) ~= 'string' then
		return false
	end
	name = lower(name)
	for _, part in ipairs(SENSITIVE_CONVAR_PARTS) do
		if find(name, part, 1, true) then
			return true
		end
	end
	return false
end

--- True for function sources that must never be inspected through debug.getupvalue.
---   @citizen:/...   system scripts (scheduler.lua, natives_*.lua, natives_loader.lua)
---   @@torii/...     torii itself
---   @Name.lua       lazily generated native stubs (their chunk name has no directory part)
---@param src any
---@return boolean
function M.is_protected_source(src)
	if type(src) ~= 'string' then
		return false
	end
	if sub(src, 1, 10) == '@citizen:/' or sub(src, 1, 8) == '@@torii/' then
		return true
	end
	return match(src, '^@[%w_]+%.lua$') ~= nil
end

--- Normalises a native hash argument the way the Lua C API (lua_tointeger) does: integers, integral
--- floats and numeric strings are all accepted. Returns an integer or nil.
local function normalize_hash(hash)
	local kind = math_type(hash)
	if kind == 'integer' then
		return hash
	elseif kind == 'float' then
		return tointeger(hash)
	elseif type(hash) == 'string' then
		local n = tonumber(hash)
		if n then
			return normalize_hash(n)
		end
	end
	return nil
end
M.normalize_hash = normalize_hash

---@param env table see spec/guard_spec.lua for the full contract
function M.install(env)
	local G = env.G
	local resource = env.resource
	local policy = env.policy
	local getinfo = env.debug.getinfo
	local now = env.now or function()
		return 0
	end

	local seen = {}
	local seen_count = 0

	local function mode()
		local ok, value = pcall(env.mode)
		return (ok and value == 'enforce') and 'enforce' or 'observe'
	end

	--- First stack frame that belongs to resource code (not torii, not system scripts, not native stubs).
	local function callsite()
		for level = 2, 14 do
			local info = getinfo(level, 'Sl')
			if not info then
				return nil
			end
			local src = info.source or ''
			if info.what ~= 'C' and not M.is_protected_source(src) and src ~= SELF_SOURCE then
				return (gsub(src, '^@@?', '')) .. ':' .. tostring(info.currentline or 0)
			end
		end
		return nil
	end

	--- Reports an event. Duplicate events (same type/reason/target/site) are collapsed for 30 s.
	local function emit(event)
		local ok = pcall(function()
			event.resource = resource
			event.mode = mode()
			event.src = callsite()
			local key = tostring(event.type)
				.. '|'
				.. tostring(event.reason)
				.. '|'
				.. tostring(event.target)
				.. '|'
				.. tostring(event.src)
			local t = now()
			if seen[key] and t - seen[key] < DEDUP_WINDOW_MS then
				return
			end
			if seen_count >= DEDUP_MAX_KEYS then
				seen, seen_count = {}, 0
			end
			if not seen[key] then
				seen_count = seen_count + 1
			end
			seen[key] = t
			env.report(event)
		end)
		return ok
	end

	-- HTTP -------------------------------------------------------------------------------------------

	--- Returns allow, decision. In observe mode `allow` is always true.
	local function http_decide(raw_url, api)
		local ok, decision = pcall(policy.check_http, policy, resource, raw_url)
		if not ok then
			-- Fail closed in enforce: a policy bug must not become a bypass. The caller just sees a network error.
			decision = { allow = false, reason = 'internal_error', target = '<error>' }
		end
		if decision.allow then
			if decision.risk then
				emit({
					type = 'http',
					api = api,
					decision = 'allow',
					level = 'warn',
					reason = 'allowed_but_risky_host:' .. decision.risk,
					target = decision.target,
				})
			end
			return true, decision
		end
		local enforce = mode() == 'enforce'
		emit({
			type = 'http',
			api = api,
			decision = enforce and 'deny' or 'would_deny',
			level = 'warn',
			reason = decision.reason,
			target = decision.target,
		})
		return not enforce, decision
	end

	local function wants_redirect_block()
		return mode() == 'enforce' and not policy:follow_redirects(resource)
	end

	--- Copies the request into a fresh plain table, reading each field exactly once. A table with
	--- metamethods could otherwise answer differently to our check and to the native.
	local function clean_request(request)
		local headers = {}
		local raw_headers = rawget(request, 'headers')
		if type(raw_headers) == 'table' then
			for k, v in next, raw_headers do
				headers[k] = v
			end
		end
		return {
			url = rawget(request, 'url'),
			method = rawget(request, 'method'),
			data = rawget(request, 'data'),
			headers = headers,
			followLocation = rawget(request, 'followLocation'),
		}
	end

	local function wrap_http_ex(orig)
		return function(request, ...)
			if type(request) ~= 'table' then
				return orig(request, ...)
			end
			local copy = clean_request(request)
			local allow = http_decide(copy.url, 'PerformHttpRequestInternalEx')
			if not allow then
				return -1
			end
			if wants_redirect_block() then
				copy.followLocation = false
			end
			return orig(copy, ...)
		end
	end

	local function wrap_http_json(orig)
		return function(payload, length, ...)
			local decoded
			if type(payload) == 'string' and env.json_decode then
				local ok, value = pcall(env.json_decode, payload)
				decoded = ok and type(value) == 'table' and value or nil
			end
			local allow = http_decide(decoded and decoded.url or nil, 'PerformHttpRequestInternal')
			if not allow then
				return -1
			end
			if decoded and wants_redirect_block() and env.json_encode then
				decoded.followLocation = false
				local ok, text = pcall(env.json_encode, decoded)
				if ok and type(text) == 'string' then
					return orig(text, #text, ...)
				end
				return -1
			end
			return orig(payload, length, ...)
		end
	end

	-- Other sensitive natives (log only, except manifest writes) --------------------------------------

	local function wrap_execute_command(orig)
		return function(command, ...)
			local name = type(command) == 'string' and match(command, '^%s*(%S+)') or '?'
			emit({
				type = 'command',
				api = 'ExecuteCommand',
				decision = 'allow',
				level = 'info',
				reason = 'logged',
				target = sub(name, 1, 64),
			})
			return orig(command, ...)
		end
	end

	local function wrap_get_convar(orig)
		return function(name, ...)
			if M.is_sensitive_convar(name) then
				emit({
					type = 'convar',
					api = 'GetConvar',
					decision = 'allow',
					level = 'warn',
					reason = 'sensitive_name',
					target = sub(lower(name), 1, 64),
				})
			end
			return orig(name, ...)
		end
	end

	local function wrap_set_http_handler(orig)
		return function(...)
			emit({
				type = 'http_handler',
				api = 'SetHttpHandler',
				decision = 'allow',
				level = 'info',
				reason = 'inbound_endpoint_registered',
				target = resource,
			})
			return orig(...)
		end
	end

	local function wrap_save_resource_file(orig)
		return function(target_resource, file_name, ...)
			if type(file_name) == 'string' then
				local base = match(lower(file_name), '([^/\\]+)$') or ''
				base = gsub(base, ':.*$', '') -- NTFS alternate data stream
				base = gsub(base, '[%. ]+$', '') -- Windows ignores trailing dots and spaces
				if base == 'fxmanifest.lua' or base == '__resource.lua' then
					local enforce = mode() == 'enforce'
					emit({
						type = 'manifest_write',
						api = 'SaveResourceFile',
						decision = enforce and 'deny' or 'would_deny',
						level = 'warn',
						reason = 'manifest_write',
						target = tostring(target_resource),
					})
					if enforce then
						return false
					end
				elseif match(base, '%.lua$') or match(base, '%.js$') then
					emit({
						type = 'code_write',
						api = 'SaveResourceFile',
						decision = 'allow',
						level = 'info',
						reason = 'logged',
						target = tostring(target_resource),
					})
				end
			end
			return orig(target_resource, file_name, ...)
		end
	end

	local WRAPPERS = {
		PerformHttpRequestInternalEx = wrap_http_ex,
		PerformHttpRequestInternal = wrap_http_json,
		ExecuteCommand = wrap_execute_command,
		GetConvar = wrap_get_convar,
		SetHttpHandler = wrap_set_http_handler,
		SaveResourceFile = wrap_save_resource_file,
	}

	local installed = {}
	local failures = {}

	for name, build in next, WRAPPERS do
		local ok, err = pcall(function()
			local orig = G[name] -- first access triggers the lazy native loader
			if type(orig) ~= 'function' then
				error('native not available: ' .. name)
			end
			rawset(G, name, build(orig))
			installed[#installed + 1] = name
		end)
		if not ok then
			failures[#failures + 1] = tostring(err)
		end
	end

	-- Citizen.InvokeNative / LoadNative ---------------------------------------------------------------
	-- Named stubs keep their own private reference to the real InvokeNative; this wrapper only matters for
	-- code that calls InvokeNative itself (the usual way to dodge name-based hooks).

	local citizen = G.Citizen
	if type(citizen) == 'table' and type(citizen.InvokeNative) == 'function' then
		local orig_invoke = citizen.InvokeNative
		local orig_load_native = citizen.LoadNative

		citizen.InvokeNative = function(hash, ...)
			local name = M.HASHES[normalize_hash(hash) or 0]
			if not name then
				return orig_invoke(hash, ...)
			end
			local first, second = ...
			if name == 'PerformHttpRequestInternalEx' then
				local decoded
				if type(first) == 'string' and env.msgpack_unpack then
					local ok, value = pcall(env.msgpack_unpack, first)
					decoded = ok and type(value) == 'table' and value or nil
				end
				local allow = http_decide(decoded and decoded.url or nil, 'InvokeNative(PerformHttpRequestInternalEx)')
				if not allow then
					return -1
				end
				if decoded and wants_redirect_block() and env.msgpack_pack then
					decoded.followLocation = false
					local ok, packed = pcall(env.msgpack_pack, decoded)
					if ok and type(packed) == 'string' then
						return orig_invoke(hash, packed, #packed, select(3, ...))
					end
					return -1
				end
			elseif name == 'PerformHttpRequestInternal' then
				local decoded
				if type(first) == 'string' and env.json_decode then
					local ok, value = pcall(env.json_decode, first)
					decoded = ok and type(value) == 'table' and value or nil
				end
				local allow = http_decide(decoded and decoded.url or nil, 'InvokeNative(PerformHttpRequestInternal)')
				if not allow then
					return -1
				end
				if decoded and wants_redirect_block() and env.json_encode then
					decoded.followLocation = false
					local ok, text = pcall(env.json_encode, decoded)
					if ok and type(text) == 'string' then
						return orig_invoke(hash, text, #text, select(3, ...))
					end
					return -1
				end
			elseif name == 'SaveResourceFile' then
				local file_name = second
				if type(file_name) == 'string' then
					local base = match(lower(file_name), '([^/\\]+)$') or ''
					base = gsub(base, ':.*$', '')
					base = gsub(base, '[%. ]+$', '')
					if base == 'fxmanifest.lua' or base == '__resource.lua' then
						local enforce = mode() == 'enforce'
						emit({
							type = 'manifest_write',
							api = 'InvokeNative(SaveResourceFile)',
							decision = enforce and 'deny' or 'would_deny',
							level = 'warn',
							reason = 'manifest_write',
							target = tostring(first),
						})
						if enforce then
							return false
						end
					end
				end
			else
				emit({
					type = 'native_direct',
					api = 'InvokeNative(' .. name .. ')',
					decision = 'allow',
					level = 'info',
					reason = 'direct_native_call',
					target = name,
				})
			end
			return orig_invoke(hash, ...)
		end

		if type(orig_load_native) == 'function' then
			citizen.LoadNative = function(name, ...)
				if type(name) == 'string' and M.WRAPPED_NAMES[name] then
					local wrapper = rawget(G, name)
					if type(wrapper) == 'function' then
						return wrapper
					end
				end
				return orig_load_native(name, ...)
			end
		end
		installed[#installed + 1] = 'Citizen.InvokeNative'
	else
		failures[#failures + 1] = 'Citizen.InvokeNative not available'
	end

	-- load ---------------------------------------------------------------------------------------------
	-- Text chunks only, always (binary chunks can corrupt the Lua VM). Dynamic code needs a grant.

	local orig_load = env.orig_load
	rawset(G, 'load', function(...)
		local chunk, chunkname, _, chunk_env = ...
		local argc = select('#', ...)
		if type(chunk) == 'string' and byte(chunk, 1) == 27 then
			emit({
				type = 'bytecode',
				api = 'load',
				decision = 'deny',
				level = 'warn',
				reason = 'binary_chunk_refused',
				target = 'bytecode',
			})
			return nil, 'torii: binary chunks are not allowed'
		end
		local ok, allow, reason = pcall(policy.check_dynamic_code, policy, resource)
		if not ok then
			allow, reason = false, 'internal_error'
		end
		if not allow then
			local enforce = mode() == 'enforce'
			emit({
				type = 'dynamic_code',
				api = 'load',
				decision = enforce and 'deny' or 'would_deny',
				level = 'warn',
				reason = reason,
				target = type(chunkname) == 'string' and sub(chunkname, 1, 80) or 'chunk',
			})
			if enforce then
				return nil, 'torii: dynamic code execution is not permitted for resource ' .. resource
			end
		end
		if argc >= 4 then
			return orig_load(chunk, chunkname, 't', chunk_env)
		end
		return orig_load(chunk, chunkname, 't')
	end)
	installed[#installed + 1] = 'load'

	-- debug.getupvalue ---------------------------------------------------------------------------------
	-- Without this, any function that captured the real InvokeNative (the scheduler, every native stub)
	-- hands it out through its upvalues, which would undo the wrappers above.

	local dbg = env.debug
	local orig_getupvalue = dbg.getupvalue
	dbg.getupvalue = function(f, index)
		if type(f) == 'function' then
			local info = getinfo(f, 'S')
			if info and M.is_protected_source(info.source) then
				return nil
			end
		end
		return orig_getupvalue(f, index)
	end
	installed[#installed + 1] = 'debug.getupvalue'

	return { installed = installed, failures = failures }
end

return M
